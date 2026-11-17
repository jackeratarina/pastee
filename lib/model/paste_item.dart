import 'package:hive/hive.dart';

import 'quick_code.dart';

/// One saved paste.
class PasteItem {
  const PasteItem({
    required this.id,
    required this.title,
    required this.content,
    required this.createdAt,
    this.sensitive = false,
    this.quickCodes = const [],
  });

  final String id;
  final String title;
  final String content;
  final DateTime createdAt;

  /// Set by the user ("always hide"): the whole item stays masked until revealed,
  /// whether or not anything in it looks like a password.
  final bool sensitive;

  /// The quick codes of this item's fields, at most one per field.
  final List<QuickCode> quickCodes;

  PasteItem copyWith({
    String? id,
    String? title,
    String? content,
    DateTime? createdAt,
    bool? sensitive,
    List<QuickCode>? quickCodes,
  }) {
    return PasteItem(
      id: id ?? this.id,
      title: title ?? this.title,
      content: content ?? this.content,
      createdAt: createdAt ?? this.createdAt,
      sensitive: sensitive ?? this.sensitive,
      quickCodes: quickCodes ?? this.quickCodes,
    );
  }
}

/// Hive adapter for [PasteItem].
///
/// Fields 0–3 match the adapter that hive_generator produced for Pastee 1.0, so
/// boxes written by 1.0 still load. Field 4 was added in 1.1; records without it
/// read as not sensitive. Field 5 (1.3) holds the quick codes and is written
/// only when there are some, so other records stay exactly as 1.2 wrote them;
/// older versions skip it. Never renumber or reuse a field index.
class PasteItemAdapter extends TypeAdapter<PasteItem> {
  @override
  final int typeId = 0;

  @override
  PasteItem read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{};
    for (var i = 0; i < numOfFields; i++) {
      fields[reader.readByte()] = reader.read();
    }
    return PasteItem(
      id: fields[0] as String,
      title: fields[1] as String,
      content: fields[2] as String,
      createdAt: fields[3] as DateTime,
      sensitive: (fields[4] as bool?) ?? false,
      quickCodes: _readCodes(fields[5]),
    );
  }

  /// A damaged entry is dropped rather than failing the whole item.
  static List<QuickCode> _readCodes(Object? value) {
    if (value is! List) return const [];
    return [
      for (final entry in value)
        if (QuickCode.fromJson(entry) case final code?) code,
    ];
  }

  @override
  void write(BinaryWriter writer, PasteItem obj) {
    final codes = obj.quickCodes;
    writer
      ..writeByte(codes.isEmpty ? 5 : 6)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.title)
      ..writeByte(2)
      ..write(obj.content)
      ..writeByte(3)
      ..write(obj.createdAt)
      ..writeByte(4)
      ..write(obj.sensitive);
    if (codes.isNotEmpty) {
      writer
        ..writeByte(5)
        ..write([for (final code in codes) code.toJson()]);
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PasteItemAdapter && typeId == other.typeId;
}
