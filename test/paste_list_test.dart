import 'package:flutter_test/flutter_test.dart';
import 'package:pastee/providers/providers.dart';
import 'package:pastee/services/storage_service.dart';

import 'support/fakes.dart';

void main() {
  test('undo brings back deleted items, but not after "Delete all"', () async {
    final notifier = PasteListNotifier(MemoryPasteStore([
      makeItem('first', id: '1'),
      makeItem('second', id: '2', minutesAgo: 1),
    ]));
    await notifier.deleteItem('1');
    expect((await notifier.undoDelete())?.id, '1');
    expect(notifier.state.map((i) => i.id), ['1', '2']);

    await notifier.deleteItem('2');
    await notifier.clearAll();
    expect(notifier.canUndo, isFalse);
    expect(await notifier.undoDelete(), isNull);
    expect(notifier.state, isEmpty);
  });

  test('a pasted secret from another item is saved as always hidden', () async {
    final notifier = PasteListNotifier(MemoryPasteStore(
        [makeItem('user: bob\npassword: abcd1234', id: 'login')]));
    final pasted = await notifier.addFromClipboard('abcd1234');
    expect(pasted!.sensitive, isTrue);
    final normal = await notifier.addFromClipboard('just a note');
    expect(normal!.sensitive, isFalse);
  });

  test('a quick double paste adds the text once', () async {
    final notifier = PasteListNotifier(MemoryPasteStore());
    final results = await Future.wait([
      notifier.addFromClipboard('same text'),
      notifier.addFromClipboard('same text'),
    ]);
    expect(results.whereType<Object>(), hasLength(1));
    expect(notifier.state, hasLength(1));
  });

  test('the list only changes after the disk write succeeds', () async {
    final notifier = PasteListNotifier(_FailingStore());
    await expectLater(
        notifier.addFromClipboard('x'), throwsA(isA<StateError>()));
    expect(notifier.state, isEmpty);
  });
}

class _FailingStore extends MemoryPasteStore {
  @override
  Future<void> put(item) async => throw StateError('disk full');
}
