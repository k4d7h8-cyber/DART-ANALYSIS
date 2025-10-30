import 'dart:convert';
import 'dart:io';

import 'package:csv/csv.dart';
import 'package:dotenv/dotenv.dart' as dotenv;
import 'package:http/http.dart' as http;
import 'package:archive/archive_io.dart';
import 'package:xml/xml.dart' as xml;

const String dartBaseUrl = 'https://opendart.fss.or.kr/api/';
const String CORP_CODE_ENDPOINT = 'corpCode.xml';
const String FIN_RPT_ENDPOINT = 'fnltt_lssum.json';

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

class ReportInfo {
  const ReportInfo({
    required this.corpCode,
    required this.corpName,
    required this.bizRepr,
    required this.bsnsYear,
    required this.fsDiv,
    required this.stockCode,
    required this.oprtPrfit,
    required this.thstrmNtic,
    required this.fnclTotasset,
  });

  factory ReportInfo.fromJson(
    Map<String, dynamic> json, {
    String fallbackCorpName = '',
  }) {
    String readField(List<String> keys, {String fallback = ''}) {
      for (final String key in keys) {
        final dynamic value = json[key];
        if (value == null) {
          continue;
        }
        final String text = value.toString().trim();
        if (text.isNotEmpty) {
          return text;
        }
      }
      return fallback;
    }

    return ReportInfo(
      corpCode: readField(<String>['corp_code']),
      corpName: readField(
        <String>['corp_name', 'corp_nm'],
        fallback: fallbackCorpName,
      ),
      bizRepr: readField(<String>['biz_repr', 'biz_rptm', 'biz_nm']),
      bsnsYear: readField(<String>['bsns_year']),
      fsDiv: readField(<String>['fs_div', 'fs_cd', 'fs_nm']),
      stockCode: readField(<String>['stock_code']),
      oprtPrfit: readField(
        <String>['oprt_prfit', 'oprt_prft', 'oper_profit'],
      ),
      thstrmNtic: readField(
        <String>['thstrm_ntic', 'thstrm_net_income', 'thstrm_ntpl_loss'],
      ),
      fnclTotasset: readField(
        <String>['fncl_totasset', 'thstrm_assets', 'tot_assets'],
      ),
    );
  }

  final String corpCode;
  final String corpName;
  final String bizRepr;
  final String bsnsYear;
  final String fsDiv;
  final String stockCode;
  final String oprtPrfit;
  final String thstrmNtic;
  final String fnclTotasset;
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

  const String targetYear = '2023';
  stdout.writeln('Fetching financial reports for $targetYear...');
  final List<ReportInfo> reports =
      await fetchFinancialReports(apiKey, targetYear);
  if (reports.isEmpty) {
    stdout.writeln('No financial reports retrieved for $targetYear.');
    return;
  }

  stdout.writeln('Retrieved ${reports.length} financial report entries.');
  await saveReportsToCsv(reports, targetYear);

  stdout.writeln('Sample reports:');
  for (final ReportInfo report in reports.take(5)) {
    stdout.writeln(
      '- ${report.corpName} (${report.corpCode}) | year: ${report.bsnsYear}, net income: ${report.thstrmNtic}',
    );
  }
}

Future<List<ReportInfo>> fetchFinancialReports(
  String apiKey,
  String targetYear,
) async {
  final File corpCsv = File(
    '${Directory.current.path}${Platform.pathSeparator}output${Platform.pathSeparator}all_corp_codes.csv',
  );
  if (!corpCsv.existsSync()) {
    stderr.writeln(
      'Corp code CSV not found at ${corpCsv.path}. Run the corp code fetch first.',
    );
    return const <ReportInfo>[];
  }

  try {
    final String csvContent = await corpCsv.readAsString(encoding: utf8);
    final List<List<dynamic>> rows =
        const CsvToListConverter().convert(csvContent);
    if (rows.length <= 1) {
      stderr.writeln('Corp code CSV does not contain any data rows.');
      return const <ReportInfo>[];
    }

    String asCleanString(dynamic value) {
      if (value == null) {
        return '';
      }
      final String text = value.toString().trim();
      if (text.isEmpty || text.toLowerCase() == 'null') {
        return '';
      }
      return text;
    }

    final List<ReportInfo> reports = <ReportInfo>[];
    final Iterable<List<dynamic>> corpRows = rows.skip(1);

    for (final List<dynamic> row in corpRows) {
      if (row.isEmpty) {
        continue;
      }
      final String corpCode = asCleanString(row.first);
      if (corpCode.isEmpty) {
        continue;
      }
      final String corpName =
          row.length > 1 ? asCleanString(row[1]) : '';

      final Uri requestUri = Uri.parse(
        '${dartBaseUrl.trim()}${FIN_RPT_ENDPOINT.trim()}'
        '?crtfc_key=$apiKey'
        '&corp_code=$corpCode'
        '&bsns_year=$targetYear'
        '&reprt_code=11011',
      );

      try {
        final http.Response response = await http.get(requestUri);
        if (response.statusCode != 200) {
          stderr.writeln(
            'HTTP ${response.statusCode} fetching financials for $corpCode.',
          );
        } else {
          final Map<String, dynamic> data =
              jsonDecode(utf8.decode(response.bodyBytes))
                  as Map<String, dynamic>;
          final String status = data['status']?.toString() ?? '';
          if (status != '000') {
            stderr.writeln(
              'DART API error for $corpCode: $status - ${data['message']}',
            );
          } else {
            final List<dynamic>? list = data['list'] as List<dynamic>?;
            if (list == null || list.isEmpty) {
              stderr.writeln(
                'No financial data returned for $corpCode ($corpName).',
              );
            } else {
              for (final dynamic item in list) {
                if (item is! Map<String, dynamic>) {
                  continue;
                }
                final ReportInfo report = ReportInfo.fromJson(
                  item,
                  fallbackCorpName: corpName,
                );
                reports.add(report);
              }
            }
          }
        }
      } catch (error) {
        stderr.writeln('Failed to fetch financials for $corpCode: $error');
      }

      await Future.delayed(const Duration(milliseconds: 500));
    }

    return reports;
  } catch (error) {
    stderr.writeln('Failed to read corp code CSV: $error');
    return const <ReportInfo>[];
  }
}

Future<void> saveReportsToCsv(
  List<ReportInfo> reports,
  String targetYear,
) async {
  final Directory outputDir = Directory('output');
  if (!outputDir.existsSync()) {
    outputDir.createSync(recursive: true);
  }

  final List<List<dynamic>> rows = <List<dynamic>>[
    <String>[
      'corp_code',
      'corp_name',
      'biz_repr',
      'bsns_year',
      'fs_div',
      'stock_code',
      'oprt_prfit',
      'thstrm_ntic',
      'fncl_totasset',
    ],
    ...reports.map(
      (ReportInfo report) => <String>[
        report.corpCode,
        report.corpName,
        report.bizRepr,
        report.bsnsYear,
        report.fsDiv,
        report.stockCode,
        report.oprtPrfit,
        report.thstrmNtic,
        report.fnclTotasset,
      ],
    ),
  ];

  final String csvData = const ListToCsvConverter().convert(rows);
  final File csvFile = File(
    '${outputDir.path}${Platform.pathSeparator}financial_reports_$targetYear.csv',
  );
  await csvFile.writeAsString(csvData, encoding: utf8);
  stdout.writeln('Saved financial reports to: ${csvFile.path}');
}
