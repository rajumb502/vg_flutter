import '../models/content_entity.dart';

abstract class VectorStore {
  Future<void> addContent(ContentEntity content);
  Future<void> addContents(List<ContentEntity> contents);
  Future<List<ContentEntity>> getAllContents();
  Future<List<ContentEntity>> getContentsByType(ContentType type);
  Future<List<ContentEntity>> searchSimilar(List<double> queryEmbedding, {int limit = 5});
  Future<void> clear();
  Future<int> get count;
}