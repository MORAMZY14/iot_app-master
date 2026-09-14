#include "../esp32_firmware/SmartHomeOffline/ControlIntentGuard.h"
#include <cassert>
#include <iostream>
int main() {
  using HomeIntent::inspect;
  assert(inspect("turn on desk lamp").state == 1);
  assert(inspect("switch tv off").state == 0);
  assert(inspect("شغل نور الممر").state == 1);
  assert(inspect("اطفي مروحة المكتب").state == 0);
  assert(inspect("turn off tv and desk lamp").blocked == false);
  assert(inspect("do not turn off the fridge").blocked);
  assert(inspect("don t turn on the oven").blocked);
  assert(inspect("turn on tv and turn off fan").blocked);
  assert(inspect("turn off all except the fridge").blocked);
  assert(inspect("if i leave turn off tv").blocked);
  assert(inspect("turn off tv after five minutes").blocked);
  assert(inspect("شغل اللمبة واطفي المروحة").state == 1);
  // Arabic attached conjunctions are normalized by the adapter below.
  assert(inspect("شغل اللمبة و اطفي المروحة").blocked);
  assert(inspect("لا شغل المروحة").blocked);
  assert(inspect("لو شغل المروحة").blocked);
  assert(inspect("what is the temperature").state == -1);
  std::cout << "16 control intent assertions passed\n";
}
