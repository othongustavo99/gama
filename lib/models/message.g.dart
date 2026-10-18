// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'message.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class MessageAdapter extends TypeAdapter<Message> {
  @override
  final int typeId = 0;

  @override
  Message read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return Message(
      id: fields[0] as String,
      role: fields[1] as String,
      content: fields[2] as String,
      conversationId: fields[4] as String,
      timestamp: fields[3] as DateTime?,
      attachmentMetadataJson: fields[5] as String? ?? '',
      variants: fields[6] == null ? null : List<String>.from(fields[6] as List),
      selectedVariantIndex: fields[7] as int? ?? 0,
    );
  }

  @override
  void write(BinaryWriter writer, Message obj) {
    writer
      ..writeByte(8)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.role)
      ..writeByte(2)
      ..write(obj.content)
      ..writeByte(3)
      ..write(obj.timestamp)
      ..writeByte(4)
      ..write(obj.conversationId)
      ..writeByte(5)
      ..write(obj.attachmentMetadataJson)
      ..writeByte(6)
      ..write(obj.variants)
      ..writeByte(7)
      ..write(obj.selectedVariantIndex);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MessageAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
