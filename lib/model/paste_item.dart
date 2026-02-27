import 'package:hive/hive.dart';

part 'paste_item.g.dart';

@HiveType(typeId: 0)
class PasteItem extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  String title;

  @HiveField(2)
  final String content;

  @HiveField(3)
  final DateTime createdAt;

  PasteItem({
    required this.id,
    required this.title,
    required this.content,
    required this.createdAt,
  });

  PasteItem copyWith({
    String? id,
    String? title,
    String? content,
    DateTime? createdAt,
  }) {
    return PasteItem(
      id: id ?? this.id,
      title: title ?? this.title,
      content: content ?? this.content,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}
