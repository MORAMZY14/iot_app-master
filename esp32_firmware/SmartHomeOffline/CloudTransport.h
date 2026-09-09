#pragma once
#include <Arduino.h>
#include <HTTPClient.h>
#include <WiFiClientSecure.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <freertos/queue.h>
#include <set>
#include <new>

// Only immutable request snapshots cross the task boundary. Device maps, NVS,
// relays and JSON application remain owned by the Arduino loop task.
class CloudTransport {
 public:
  enum Method { Get, Put, Patch, Sse };
  struct Request {
    Method method;
    String path, body, response;
    uint32_t revision;
    int status;
    Request(Method m, const String& p, const String& b, uint32_t r)
      : method(m), path(p), body(b), revision(r), status(-1) {}
  };
  bool begin(const String& baseUrl, WiFiClientSecure* stream) {
    url_ = baseUrl;
    while (url_.endsWith("/")) url_.remove(url_.length() - 1);
    host_ = url_.substring(url_.indexOf("://") + 3);
    stream_ = stream;
    jobs_ = xQueueCreate(8, sizeof(Request*));
    results_ = xQueueCreate(8, sizeof(Request*));
    if (!jobs_ || !results_) return false;
    return xTaskCreate(workerEntry, "cloud_io", 8192, this, 1, &task_) == pdPASS;
  }
  bool enqueue(Method method, const String& path, const String& body = "", uint32_t revision = 0) {
    if (!task_ || path.length() > 512 || body.length() > 16384) return false;
    const String key = String(static_cast<int>(method)) + path;
    if ((method == Get || method == Sse) && pending_.count(key)) return false;
    Request* request = new (std::nothrow) Request(method, path, body, revision);
    if (!request) return false;
    if (xQueueSend(jobs_, &request, 0) != pdTRUE) { delete request; return false; }
    if (method == Get || method == Sse) pending_.insert(key);
    return true;
  }
  Request* receive() {
    Request* request = nullptr;
    if (!results_ || xQueueReceive(results_, &request, 0) != pdTRUE) return nullptr;
    if (request->method == Get || request->method == Sse)
      pending_.erase(String(static_cast<int>(request->method)) + request->path);
    return request;
  }
 private:
  // HTTPClient decodes chunked bodies into this bounded sink.
  class ResponseSink : public Stream {
   public:
    String text;
    bool overflow = false;
    size_t write(uint8_t c) override { return write(&c, 1); }
    size_t write(const uint8_t* data, size_t length) override {
      if (text.length() + length > 16384 || !text.concat(reinterpret_cast<const char*>(data), length)) {
        overflow = true; return 0;
      }
      return length;
    }
    int available() override { return 0; }
    int read() override { return -1; }
    int peek() override { return -1; }
    void flush() override {}
  };
  String url_, host_;
  WiFiClientSecure* stream_ = nullptr;
  QueueHandle_t jobs_ = nullptr, results_ = nullptr;
  TaskHandle_t task_ = nullptr;
  std::set<String> pending_; // touched only by loop(), never by the worker
  static void workerEntry(void* value) { static_cast<CloudTransport*>(value)->worker(); }
  void worker() {
    for (;;) {
      Request* request = nullptr;
      if (xQueueReceive(jobs_, &request, portMAX_DELAY) != pdTRUE) continue;
      if (WiFi.status() == WL_CONNECTED) {
        if (request->method == Sse) {
          stream_->setInsecure(); // preserves the development firmware's TLS policy
          stream_->setTimeout(1);
          stream_->setHandshakeTimeout(2);
          if (stream_->connect(host_.c_str(), 443, 1500)) {
            stream_->print("GET " + request->path + " HTTP/1.1\r\nHost: " + host_ +
                           "\r\nAccept: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n");
            request->status = 200;
          }
        } else {
          WiFiClientSecure connection;
          connection.setInsecure();
          connection.setHandshakeTimeout(2);
          HTTPClient http;
          http.setConnectTimeout(1500);
          http.setTimeout(1500);
          http.setReuse(false);
          if (http.begin(connection, url_ + request->path)) {
            http.addHeader("Content-Type", "application/json");
            if (request->method == Get) request->status = http.GET();
            else if (request->method == Put) request->status = http.PUT(request->body);
            else request->status = http.PATCH(request->body);
            if (request->method == Get && request->status == 200) {
              ResponseSink sink;
              if (http.writeToStream(&sink) >= 0 && !sink.overflow) request->response = sink.text;
              else request->status = -2;
            }
            http.end();
          }
        }
      }
      // Waiting here cannot block HTTP/BLE: only this network worker waits.
      xQueueSend(results_, &request, portMAX_DELAY);
    }
  }
};
