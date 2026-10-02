import 'package:flutter_test/flutter_test.dart';
import 'package:iot/ellie/local_command_proposal_guard.dart';

void main() {
  test('normalization retains multiword names and action direction', () {
    expect(
      LocalCommandProposalGuard.preservesUserScope(
        'Please switch the Desk Lamp and TV off',
        'turn off Desk Lamp and TV',
      ),
      isTrue,
    );
    expect(
      LocalCommandProposalGuard.preservesUserScope(
        'Hey Nova turn off Desk Lamp',
        'power off Desk Lamp',
        assistantName: 'Nova',
      ),
      isTrue,
    );
  });

  test('a model cannot collapse opposite actions into a single direction', () {
    expect(
      LocalCommandProposalGuard.preservesUserScope(
        'turn on Desk Lamp and turn off Heater',
        'turn on Desk Lamp and Heater',
      ),
      isFalse,
    );
    expect(
      LocalCommandProposalGuard.preservesUserScope(
        'turn off Desk Lamp and Heater',
        'turn off Desk Lamp and turn on Heater',
      ),
      isFalse,
    );
    expect(
      LocalCommandProposalGuard.preservesUserScope(
        'شغلي المصباح واطفي التلفزيون',
        'شغلي المصباح والتلفزيون',
      ),
      isFalse,
    );
  });

  test('target qualifiers, target nouns and order cannot be dropped or changed', () {
    for (final proposed in <String>[
      'turn on Lamp',
      'turn on Desk',
      'turn on Lamp Desk',
      'turn on Desk Lamp and Heater',
    ]) {
      expect(
        LocalCommandProposalGuard.preservesUserScope(
          'turn on Desk Lamp',
          proposed,
        ),
        isFalse,
        reason: proposed,
      );
    }
    expect(
      LocalCommandProposalGuard.preservesUserScope(
        'turn off Power Lamp',
        'turn off Lamp',
      ),
      isFalse,
    );
    expect(
      LocalCommandProposalGuard.preservesUserScope(
        'turn off Living Room',
        'turn off Living',
      ),
      isFalse,
    );
  });

  test('all-device commands retain room scope and exclusions require parsing', () {
    expect(
      LocalCommandProposalGuard.preservesUserScope(
        'turn off all devices in Bedroom',
        'turn off all devices',
      ),
      isFalse,
    );
    expect(
      LocalCommandProposalGuard.preservesUserScope(
        'turn off all devices in Bedroom',
        'power off all devices in Bedroom',
      ),
      isTrue,
    );
    for (final original in <String>[
      'turn on Desk Lamp but leave Heater off',
      'do not turn on Desk Lamp',
      'turn on all devices except Heater',
      'لا تشغل المصباح',
    ]) {
      expect(
        LocalCommandProposalGuard.preservesUserScope(
          original,
          original,
        ),
        isFalse,
        reason: original,
      );
    }
  });
}
