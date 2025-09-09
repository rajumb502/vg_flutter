import 'package:objectbox/objectbox.dart';

enum ContentType {
  email,
  document,
  calendar,
  contact,
  note,
}

@Entity()
class ContentEntity {
  @Id()
  int id = 0;

  String sourceId;
  String title;
  String? author;
  String content;
  
  @Property(type: PropertyType.date)
  DateTime createdDate;
  
  @Property(type: PropertyType.byte)
  int contentTypeIndex;
  
  @Property(type: PropertyType.floatVector)
  List<double>? embedding;

  ContentEntity({
    this.id = 0,
    required this.sourceId,
    required this.title,
    this.author,
    required this.content,
    required this.createdDate,
    required this.contentTypeIndex,
    this.embedding,
  });
  
  // Helper constructor
  ContentEntity.create({
    required this.sourceId,
    required this.title,
    this.author,
    required this.content,
    required this.createdDate,
    required ContentType contentType,
    this.embedding,
  }) : contentTypeIndex = contentType.index;
  
  ContentType get contentType => ContentType.values[contentTypeIndex];
  set contentType(ContentType type) => contentTypeIndex = type.index;
}