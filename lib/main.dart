import 'dart:convert';
import 'dart:io';

import 'package:csv/csv.dart';
import 'package:dotenv/dotenv.dart' as dotenv;
import 'package:http/http.dart' as http;
import 'package:archive/archive_io.dart';
import 'package:xml/xml.dart' as xml;

const String dartBaseUrl = 'https://opendart.fss.or.kr/api/';
const String CORP_CODE_ENDPOINT = 'corpCode.xml';

class CorpInfo {
  const CorpInfo({
    required this.corpCode,
    required this.corpName,
    required this.stockCode,
    required this.modifyDate,
  });

  factory CorpInfo.fromJson(Map<String, dynamic> json) {
    return CorpInfo(
      corpCode: json['corp_code']?.toString() ?? '',
      corpName: json['corp_name']?.toString() ?? '',
      stockCode: json['stock_code']?.toString() ?? '',
      modifyDate: json['modify_date']?.toString() ?? '',
    );
  }

  final String corpCode;
  final String corpName;
  final String stockCode;
  final String modifyDate;
}

Future<List<CorpInfo>> fetchAllCorpCodes(String apiKey) async {
  final Uri requestUri = Uri.parse(
    '${dartBaseUrl.trim()}${CORP_CODE_ENDPOINT.trim()}?crtfc_key=$apiKey',
  );

  try {
    final http.Response response = await http.get(requestUri);
    if (response.statusCode != 200) {
      stderr.writeln(
        'HTTP error while fetching corp codes: ${response.statusCode}',
      );
      return const <CorpInfo>[];
    }

    final List<int> zipBytes = response.bodyBytes;
    if (zipBytes.isEmpty) {
      stderr.writeln('Empty response while fetching corp codes.');
      return const <CorpInfo>[];
    }

    final Archive archive = ZipDecoder().decodeBytes(zipBytes, verify: true);
    final ArchiveFile? corpFile = archive.files.firstWhere(
      (ArchiveFile file) =>
          file.isFile && file.name.toUpperCase() == 'CORPCODE.XML',
      orElse: () => ArchiveFile('', 0, null),
    );

    if (corpFile?.content == null) {
      stderr.writeln('CORPCODE.xml not found in the downloaded archive.');
      return const <CorpInfo>[];
    }

    final List<int> xmlBytes = corpFile!.content as List<int>;
    final String xmlString = utf8.decode(xmlBytes, allowMalformed: true);
    final xml.XmlDocument document = xml.XmlDocument.parse(xmlString);

    final Iterable<xml.XmlElement> entries = document.findAllElements('list');
    if (entries.isEmpty) {
      stderr.writeln('No <list> elements found in CORPCODE.xml.');
      return const <CorpInfo>[];
    }

    return entries
        .map(
          (xml.XmlElement element) => CorpInfo(
            corpCode: element.getElement('corp_code')?.text.trim() ?? '',
            corpName: element.getElement('corp_name')?.text.trim() ?? '',
            stockCode: element.getElement('stock_code')?.text.trim() ?? '',
            modifyDate: element.getElement('modify_date')?.text.trim() ?? '',
          ),
        )
        .where((CorpInfo corp) =>
            corp.corpCode.isNotEmpty && corp.corpName.isNotEmpty)
        .toList(growable: false);
  } catch (error) {
    stderr.writeln('Failed to fetch corp codes: $error');
    return const <CorpInfo>[];
  }
}

Future<void> saveToCsv(List<CorpInfo> corpList) async {
  final Directory outputDir = Directory('output');
  if (!outputDir.existsSync()) {
    outputDir.createSync(recursive: true);
  }

  final List<List<dynamic>> rows = <List<dynamic>>[
    <String>['corp_code', 'corp_name', 'stock_code', 'modify_date'],
    ...corpList.map(
      (CorpInfo corp) => <String>[
        corp.corpCode,
        corp.corpName,
        corp.stockCode,
        corp.modifyDate,
      ],
    ),
  ];

  final String csvData = const ListToCsvConverter().convert(rows);
  final File csvFile = File('${outputDir.path}${Platform.pathSeparator}all_corp_codes.csv');
  await csvFile.writeAsString(csvData, encoding: utf8);
  stdout.writeln('Saved CSV to: ${csvFile.path}');
}

Future<void> main() async {
  final dotenv.DotEnv env = dotenv.DotEnv()..load(['.env']);
  final String? apiKey = env['DART_API_KEY'];

  if (apiKey == null || apiKey.isEmpty) {
    stdout.writeln(
      'Missing DART_API_KEY. Please update the .env file with your API key.',
    );
    return;
  }

  stdout.writeln('Fetching corp codes from DART API...');
  final List<CorpInfo> corpList = await fetchAllCorpCodes(apiKey);
  if (corpList.isEmpty) {
    stdout.writeln('No corp codes retrieved from DART API.');
    return;
  }

  stdout.writeln('Top 5 corporations:');
  for (final CorpInfo corp in corpList.take(5)) {
    stdout.writeln(
      '- ${corp.corpName} (corp_code: ${corp.corpCode}, stock_code: ${corp.stockCode}, modify_date: ${corp.modifyDate})',
    );
  }

  await saveToCsv(corpList);
}
