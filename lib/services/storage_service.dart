import 'package:hive_flutter/hive_flutter.dart';
import 'package:pastee/model/paste_item.dart';

class StorageService {
  static const String _boxName = 'paste_items';
  late Box<PasteItem> _box;

  Future<void> init() async {
    await Hive.initFlutter();
    Hive.registerAdapter(PasteItemAdapter());
    _box = await Hive.openBox<PasteItem>(_boxName);
  }

  List<PasteItem> getAll() {
    final items = _box.values.toList();
    items.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return items;
  }

  Future<void> add(PasteItem item) async {
    await _box.put(item.id, item);
  }

  Future<void> update(PasteItem item) async {
    await _box.put(item.id, item);
  }

  Future<void> delete(String id) async {
    await _box.delete(id);
  }

  Future<void> clear() async {
    await _box.clear();
  }
}
