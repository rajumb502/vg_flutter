enum ContentType {
  email,
  document,
  calendar,
  contact,
  note,
}

class ContentEntity {
  int id = 0;
  String sourceId;
  String title;
  String? author;
  String content;
  DateTime createdDate;
  int contentTypeIndex;
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