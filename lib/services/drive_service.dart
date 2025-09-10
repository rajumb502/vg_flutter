import 'package:googleapis/drive/v3.dart';
import 'package:googleapis/sheets/v4.dart';
import 'package:googleapis_auth/auth_io.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:archive/archive.dart';
import 'package:xml/xml.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'dart:typed_data';
import '../models/content_entity.dart';
import 'embedding_service.dart';
import 'simple_logger.dart';

class DriveService {
  final String _apiKey;
  late final EmbeddingService _embeddingService;

  Future<int> get _maxFileSizeBytes async {
    final prefs = await SharedPreferences.getInstance();
    final mb = prefs.getInt('max_file_size_mb') ?? 2;
    return mb * 1024 * 1024;
  }

  // Supported file types - only those we can extract meaningful content from
  static const _supportedMimeTypes = [
    'text/plain',
    'application/vnd.google-apps.document',
    'application/vnd.google-apps.spreadsheet',
    'application/pdf',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'application/vnd.oasis.opendocument.text',
    'application/vnd.oasis.opendocument.spreadsheet',
    'application/vnd.oasis.opendocument.presentation',
  ];

  DriveService(this._apiKey) {
    _embeddingService = EmbeddingService(_apiKey);
  }

  Future<List<ContentEntity>> fetchDriveFiles(
    AuthClient authClient, {
    bool forceReindex = false,
  }) async {
    final drive = DriveApi(authClient);

    // Get last sync time
    final prefs = await SharedPreferences.getInstance();
    final lastSyncTime = forceReindex
        ? null
        : prefs.getInt('drive_last_sync_time');
    final modifiedTime = lastSyncTime != null
        ? DateTime.fromMillisecondsSinceEpoch(lastSyncTime).toIso8601String()
        : null;

    // Build query for supported file types
    final mimeQuery = _supportedMimeTypes
        .map((type) => "mimeType='$type'")
        .join(' or ');
    final query = modifiedTime != null
        ? '($mimeQuery) and modifiedTime > "$modifiedTime"'
        : '($mimeQuery)';

    SimpleLogger.log('Drive query: $query');
    final fileList = await drive.files.list(
      q: query,
      pageSize: 50,
      $fields: 'files(id,name,mimeType,modifiedTime,size)',
    );

    SimpleLogger.log('Found ${fileList.files?.length ?? 0} files');
    final documents = <ContentEntity>[];
    final maxConcurrency = prefs.getInt('max_concurrent_requests') ?? 3;

    // Process files in parallel batches
    final validFiles = (fileList.files ?? [])
        .where((file) => file.id != null && file.name != null)
        .where((file) => _supportedMimeTypes.contains(file.mimeType))
        .toList();

    for (int i = 0; i < validFiles.length; i += maxConcurrency) {
      final batch = validFiles.skip(i).take(maxConcurrency).toList();
      final batchResults = await Future.wait(
        batch.map((file) => _processFileWithEmbedding(drive, file, authClient)),
        eagerError: false,
      );

      for (final result in batchResults) {
        if (result != null) documents.addAll(result);
      }
      
      // Rate limiting between batches
      if (i + maxConcurrency < validFiles.length) {
        final rateLimitSeconds = prefs.getInt('rate_limit_seconds') ?? 15;
        SimpleLogger.log('Rate limiting: waiting ${rateLimitSeconds}s before next batch');
        await Future.delayed(Duration(seconds: rateLimitSeconds));
      }
    }

    // Update last sync time only if we actually processed files
    if (fileList.files?.isNotEmpty == true) {
      final currentTime = DateTime.now().millisecondsSinceEpoch;
      await prefs.setInt('drive_last_sync_time', currentTime);
    }

    return documents;
  }

  Future<List<ContentEntity>?> _processFileWithEmbedding(
    DriveApi drive,
    File file,
    AuthClient authClient,
  ) async {
    try {
      // Skip files that are too large
      final fileSize = int.tryParse(file.size ?? '0') ?? 0;
      final maxSize = await _maxFileSizeBytes;
      if (fileSize > maxSize) {
        SimpleLogger.log(
          'Skipping large file: ${file.name} (${(fileSize / 1024 / 1024).toStringAsFixed(1)}MB)',
        );
        return null;
      }

      SimpleLogger.log('Processing file: ${file.name} (${file.mimeType})');
      final content = await _extractFileContent(drive, file, authClient);
      if (content.isEmpty) {
        SimpleLogger.log('No content extracted from ${file.name}');
        return null;
      }

      // Check content size after extraction
      final contentSizeBytes = content.length * 2;
      final maxContentSize = await _maxFileSizeBytes;
      if (contentSizeBytes > maxContentSize) {
        SimpleLogger.log(
          'Skipping large content: ${file.name} (${(contentSizeBytes / 1024 / 1024).toStringAsFixed(1)}MB extracted)',
        );
        return null;
      }

      SimpleLogger.log(
        'Extracted ${content.length} characters from ${file.name}',
      );

      final document = ContentEntity.create(
        sourceId: file.id!,
        title: file.name!,
        author: 'Google Drive',
        content: content,
        createdDate: file.modifiedTime ?? DateTime.now(),
        contentType: ContentType.document,
      );

      final fullText = '${document.title} ${document.content}';
      final chunkEntities = _embeddingService.createChunkedEntities(
        document,
        fullText,
      );

      // Store content immediately without embeddings
      return chunkEntities;
    } catch (e) {
      SimpleLogger.log('Error processing file ${file.name}: $e');
      return null;
    }
  }

  Future<void> generateMissingEmbeddings() async {
    SimpleLogger.log('Starting background embedding generation...');
    
    try {
      final textsToEmbed = <String>[];
      final entitiesToEmbed = <ContentEntity>[];
      
      // This would need to be called with a vector store instance
      // For now, this is a placeholder - the actual implementation
      // will be in main.dart where we have access to the vector store
      
      await _embeddingService.generateEmbeddingsBatch(
        textsToEmbed,
        entitiesToEmbed,
      );
      
      SimpleLogger.log('Background embedding generation completed');
    } catch (e) {
      SimpleLogger.log('Background embedding generation failed: $e');
    }
  }

  Future<String> _extractFileContent(
    DriveApi drive,
    File file,
    AuthClient authClient,
  ) async {
    try {
      switch (file.mimeType) {
        case 'text/plain':
          return await _downloadTextFile(drive, file.id!);

        case 'application/vnd.google-apps.document':
          return await _exportGoogleDoc(drive, file.id!);

        case 'application/vnd.google-apps.spreadsheet':
          return await _exportGoogleSheetAsJson(authClient, file.id!);

        case 'application/pdf':
          return await _extractPdfContent(drive, file.id!);

        case 'application/vnd.openxmlformats-officedocument.wordprocessingml.document':
          return await _extractDocxContent(drive, file.id!);

        case 'application/vnd.openxmlformats-officedocument.presentationml.presentation':
          return await _extractPptxContent(drive, file.id!);

        case 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet':
          return await _extractXlsxContent(drive, file.id!);

        case 'application/vnd.oasis.opendocument.text':
        case 'application/vnd.oasis.opendocument.spreadsheet':
        case 'application/vnd.oasis.opendocument.presentation':
          return await _extractOdfContent(drive, file.id!);

        default:
          return '';
      }
    } catch (e) {
      SimpleLogger.log('Error extracting content from ${file.name}: $e');
      return '';
    }
  }

  Future<String> _downloadTextFile(DriveApi drive, String fileId) async {
    final media =
        await drive.files.get(
              fileId,
              downloadOptions: DownloadOptions.fullMedia,
            )
            as Media;
    final bytes = <int>[];
    await for (final chunk in media.stream) {
      bytes.addAll(chunk);
    }
    return String.fromCharCodes(bytes);
  }

  Future<String> _exportGoogleDoc(DriveApi drive, String fileId) async {
    final media =
        await drive.files.export(
              fileId,
              'text/plain',
              downloadOptions: DownloadOptions.fullMedia,
            )
            as Media;
    final bytes = <int>[];
    await for (final chunk in media.stream) {
      bytes.addAll(chunk);
    }
    return String.fromCharCodes(bytes);
  }

  Future<String> _exportGoogleSheetAsJson(
    AuthClient authClient,
    String fileId,
  ) async {
    try {
      final sheets = SheetsApi(authClient);

      // Get spreadsheet metadata to find all sheets
      final spreadsheet = await sheets.spreadsheets.get(fileId);
      final allSheets = <String, List<Map<String, String>>>{};

      // Process each sheet
      for (final sheet in spreadsheet.sheets ?? []) {
        final sheetName = sheet.properties?.title ?? 'Unknown';
        final range = '$sheetName!A:Z'; // Get all data from A to Z columns

        try {
          final response = await sheets.spreadsheets.values.get(fileId, range);
          final values = response.values ?? [];

          if (values.isNotEmpty) {
            final headers = values[0].map((h) => h?.toString() ?? '').toList();
            final rows = <Map<String, String>>[];

            for (int i = 1; i < values.length; i++) {
              final row = <String, String>{};
              final rowValues = values[i];

              for (int j = 0; j < headers.length; j++) {
                final header = headers[j];
                final value = j < rowValues.length
                    ? (rowValues[j]?.toString() ?? '')
                    : '';
                row[header] = value;
              }

              if (row.values.any((v) => v.isNotEmpty)) {
                rows.add(row);
              }
            }

            allSheets[sheetName] = rows;
          }
        } catch (e) {
          SimpleLogger.log('Error reading sheet $sheetName: $e');
        }
      }

      return _mapToJsonString(allSheets);
    } catch (e) {
      SimpleLogger.log('Error exporting Google Sheet: $e');
      return '';
    }
  }

  Future<String> _extractPdfContent(DriveApi drive, String fileId) async {
    try {
      final media =
          await drive.files.get(
                fileId,
                downloadOptions: DownloadOptions.fullMedia,
              )
              as Media;
      final bytes = <int>[];
      await for (final chunk in media.stream) {
        bytes.addAll(chunk);
      }

      final document = PdfDocument(inputBytes: Uint8List.fromList(bytes));
      final extractor = PdfTextExtractor(document);
      final text = extractor.extractText();
      document.dispose();
      return text;
    } catch (e) {
      SimpleLogger.log('Error extracting PDF content: $e');
      return '';
    }
  }

  Future<String> _extractDocxContent(DriveApi drive, String fileId) async {
    try {
      final media =
          await drive.files.get(
                fileId,
                downloadOptions: DownloadOptions.fullMedia,
              )
              as Media;
      final bytes = <int>[];
      await for (final chunk in media.stream) {
        bytes.addAll(chunk);
      }

      final archive = ZipDecoder().decodeBytes(bytes);
      final documentXml = archive.findFile('word/document.xml');
      if (documentXml == null) return '';

      final content = String.fromCharCodes(documentXml.content);
      final document = XmlDocument.parse(content);
      final textNodes = document.findAllElements('w:t');
      return textNodes.map((node) => node.innerText).join(' ');
    } catch (e) {
      SimpleLogger.log('Error extracting DOCX content: $e');
      return '';
    }
  }

  Future<String> _extractPptxContent(DriveApi drive, String fileId) async {
    try {
      final media =
          await drive.files.get(
                fileId,
                downloadOptions: DownloadOptions.fullMedia,
              )
              as Media;
      final bytes = <int>[];
      await for (final chunk in media.stream) {
        bytes.addAll(chunk);
      }

      final archive = ZipDecoder().decodeBytes(bytes);
      final textContent = <String>[];

      for (final file in archive.files) {
        if (file.name.startsWith('ppt/slides/slide') &&
            file.name.endsWith('.xml')) {
          final content = String.fromCharCodes(file.content);
          final document = XmlDocument.parse(content);
          final textNodes = document.findAllElements('a:t');
          textContent.addAll(textNodes.map((node) => node.innerText));
        }
      }
      return textContent.join(' ');
    } catch (e) {
      SimpleLogger.log('Error extracting PPTX content: $e');
      return '';
    }
  }

  Future<String> _extractXlsxContent(DriveApi drive, String fileId) async {
    try {
      final media =
          await drive.files.get(
                fileId,
                downloadOptions: DownloadOptions.fullMedia,
              )
              as Media;
      final bytes = <int>[];
      await for (final chunk in media.stream) {
        bytes.addAll(chunk);
      }

      final archive = ZipDecoder().decodeBytes(bytes);
      final sharedStrings = <String>[];

      // Extract shared strings
      final sharedStringsXml = archive.findFile('xl/sharedStrings.xml');
      if (sharedStringsXml != null) {
        final content = String.fromCharCodes(sharedStringsXml.content);
        final document = XmlDocument.parse(content);
        final stringNodes = document.findAllElements('t');
        sharedStrings.addAll(stringNodes.map((node) => node.innerText));
      }

      final allContent = <String>[];

      // Extract worksheet content
      for (final file in archive.files) {
        if (file.name.startsWith('xl/worksheets/sheet') &&
            file.name.endsWith('.xml')) {
          final content = String.fromCharCodes(file.content);
          final document = XmlDocument.parse(content);
          final cellNodes = document.findAllElements('c');

          for (final cell in cellNodes) {
            final valueNode = cell.findElements('v').firstOrNull;
            if (valueNode != null) {
              final value = valueNode.innerText;
              final type = cell.getAttribute('t');
              if (type == 's' && int.tryParse(value) != null) {
                final index = int.parse(value);
                if (index < sharedStrings.length) {
                  allContent.add(sharedStrings[index]);
                }
              } else {
                allContent.add(value);
              }
            }
          }
        }
      }
      return allContent.join(' ');
    } catch (e) {
      SimpleLogger.log('Error extracting XLSX content: $e');
      return '';
    }
  }

  Future<String> _extractOdfContent(DriveApi drive, String fileId) async {
    try {
      final media =
          await drive.files.get(
                fileId,
                downloadOptions: DownloadOptions.fullMedia,
              )
              as Media;
      final bytes = <int>[];
      await for (final chunk in media.stream) {
        bytes.addAll(chunk);
      }

      final archive = ZipDecoder().decodeBytes(bytes);
      final contentXml = archive.findFile('content.xml');
      if (contentXml == null) return '';

      final content = String.fromCharCodes(contentXml.content);
      final document = XmlDocument.parse(content);
      final textNodes = document.findAllElements('text:p');
      return textNodes.map((node) => node.innerText).join(' ');
    } catch (e) {
      SimpleLogger.log('Error extracting ODF content: $e');
      return '';
    }
  }

  String _mapToJsonString(Map<String, dynamic> map) {
    final buffer = StringBuffer();
    buffer.write('{');

    final entries = map.entries.toList();
    for (int i = 0; i < entries.length; i++) {
      final entry = entries[i];
      buffer.write('"${entry.key}": ');

      if (entry.value is List) {
        buffer.write('[');
        final list = entry.value as List;
        for (int j = 0; j < list.length; j++) {
          if (list[j] is Map) {
            buffer.write(_mapToJsonString(list[j] as Map<String, dynamic>));
          } else {
            buffer.write('"${list[j]}"');
          }
          if (j < list.length - 1) buffer.write(', ');
        }
        buffer.write(']');
      } else if (entry.value is Map) {
        buffer.write(_mapToJsonString(entry.value as Map<String, dynamic>));
      } else {
        buffer.write('"${entry.value}"');
      }

      if (i < entries.length - 1) buffer.write(', ');
    }

    buffer.write('}');
    return buffer.toString();
  }
}
