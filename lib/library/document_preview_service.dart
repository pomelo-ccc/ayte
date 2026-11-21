import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Categorized document types supported in Ayte's Library & side preview.
enum LibraryDocKind {
  pdf,
  word,
  excel,
  powerpoint,
  image,
  markdown,
  html,
  data,
  other;

  static LibraryDocKind fromPath(String filePath) {
    final ext = p.extension(filePath).toLowerCase();
    return switch (ext) {
      '.pdf' => pdf,
      '.docx' => word,
      '.xlsx' => excel,
      '.pptx' => powerpoint,
      '.png' || '.jpg' || '.jpeg' || '.webp' || '.gif' || '.svg' => image,
      '.md' || '.markdown' => markdown,
      '.html' || '.htm' => html,
      '.csv' || '.json' || '.yaml' || '.yml' => data,
      _ => other,
    };
  }

  bool get isOfficeOrPdf =>
      this == pdf || this == word || this == excel || this == powerpoint;
}

class ExcelSheetPreview {
  const ExcelSheetPreview({required this.name, required this.rows});

  final String name;
  final List<List<String>> rows;
}

class PptSlidePreview {
  const PptSlidePreview({required this.index, required this.lines});

  final int index;
  final List<String> lines;
}

class DocumentPreviewResult {
  const DocumentPreviewResult({
    required this.kind,
    this.text = '',
    this.sheets = const [],
    this.slides = const [],
    this.error,
  });

  final LibraryDocKind kind;
  final String text;
  final List<ExcelSheetPreview> sheets;
  final List<PptSlidePreview> slides;
  final String? error;
}

/// Extracts structured previews for `.docx`, `.xlsx`, `.pptx`, and `.pdf`
/// locally with zero external packages using Python 3 standard library.
abstract final class DocumentPreviewService {
  static Future<DocumentPreviewResult> loadPreview(String filePath) async {
    final kind = LibraryDocKind.fromPath(filePath);
    final file = File(filePath);
    if (!file.existsSync()) {
      return DocumentPreviewResult(kind: kind, error: 'File not found');
    }

    switch (kind) {
      case LibraryDocKind.word:
        return _parseDocx(filePath);
      case LibraryDocKind.excel:
        return _parseXlsx(filePath);
      case LibraryDocKind.powerpoint:
        return _parsePptx(filePath);
      case LibraryDocKind.pdf:
        return _parsePdf(filePath);
      case LibraryDocKind.image:
        return DocumentPreviewResult(kind: kind, text: filePath);
      case LibraryDocKind.markdown ||
          LibraryDocKind.html ||
          LibraryDocKind.data ||
          LibraryDocKind.other:
        try {
          final raw = await file.readAsString();
          return DocumentPreviewResult(
            kind: kind,
            text: raw.length > 40000 ? '${raw.substring(0, 40000)}\n...' : raw,
          );
        } on Object catch (e) {
          return DocumentPreviewResult(kind: kind, error: '$e');
        }
    }
  }

  static Future<DocumentPreviewResult> _parseDocx(String path) async {
    const py = r'''
import sys, zipfile, xml.etree.ElementTree as ET
path = sys.argv[1]
ns = {'w': 'http://schemas.openxmlformats.org/wordprocessingml/2006/main'}
out = []
with zipfile.ZipFile(path) as z:
    root = ET.fromstring(z.read('word/document.xml'))
    for p in root.findall('.//w:body/w:p', ns):
        texts = [t.text for t in p.findall('.//w:t', ns) if t.text]
        line = ''.join(texts).strip()
        if line:
            out.append(line)
    for tbl in root.findall('.//w:body/w:tbl', ns):
        out.append('')
        for tr in tbl.findall('.//w:tr', ns):
            cells = []
            for tc in tr.findall('.//w:tc', ns):
                ct = ''.join(t.text for t in tc.findall('.//w:t', ns) if t.text).strip()
                cells.append(ct.replace('|', '/'))
            if cells:
                out.append('| ' + ' | '.join(cells) + ' |')
print('\n\n'.join(out)[:35000])
''';
    return _runTextPython(LibraryDocKind.word, py, path);
  }

  static Future<DocumentPreviewResult> _parseXlsx(String path) async {
    const py = r'''
import sys, json, zipfile, xml.etree.ElementTree as ET
path = sys.argv[1]
sheets = []
with zipfile.ZipFile(path) as z:
    shared = []
    if 'xl/sharedStrings.xml' in z.namelist():
        sr = ET.fromstring(z.read('xl/sharedStrings.xml'))
        for si in sr:
            shared.append(''.join(t.text or '' for t in si.iter() if t.tag.endswith('}t')))
    sheet_names = {}
    if 'xl/workbook.xml' in z.namelist():
        wb = ET.fromstring(z.read('xl/workbook.xml'))
        idx = 1
        for sh in wb.iter():
            if sh.tag.endswith('}sheet'):
                sheet_names[idx] = sh.attrib.get('name', f'Sheet{idx}')
                idx += 1
    sheet_files = sorted(n for n in z.namelist() if n.startswith('xl/worksheets/sheet') and n.endswith('.xml'))
    for i, sf in enumerate(sheet_files[:12], start=1):
        root = ET.fromstring(z.read(sf))
        rows = []
        for row in root.iter():
            if not row.tag.endswith('}row'): continue
            vals = []
            for c in row:
                if not c.tag.endswith('}c'): continue
                t = c.attrib.get('t', '')
                v = ''
                for child in c:
                    if child.tag.endswith('}v') and child.text is not None:
                        if t == 's':
                            idx_s = int(child.text)
                            v = shared[idx_s] if 0 <= idx_s < len(shared) else child.text
                        else:
                            v = child.text
                    elif child.tag.endswith('}is'):
                        v = ''.join(x.text or '' for x in child.iter() if x.tag.endswith('}t'))
                vals.append(v)
            if any(x.strip() for x in vals):
                rows.append(vals[:24])
            if len(rows) >= 120:
                break
        sheets.append({'name': sheet_names.get(i, f'Sheet{i}'), 'rows': rows})
print(json.dumps(sheets, ensure_ascii=False))
''';
    try {
      final res = await Process.run('python3', ['-c', py, path]);
      if (res.exitCode != 0) {
        return DocumentPreviewResult(
          kind: LibraryDocKind.excel,
          error: '${res.stderr}'.trim(),
        );
      }
      final decoded = jsonDecode('${res.stdout}');
      final sheets = <ExcelSheetPreview>[];
      if (decoded is List) {
        for (final item in decoded) {
          if (item is Map) {
            final rows = <List<String>>[
              if (item['rows'] case final List rawRows)
                for (final r in rawRows)
                  if (r is List) [for (final c in r) '$c'],
            ];
            sheets.add(
              ExcelSheetPreview(
                name: '${item['name'] ?? 'Sheet'}',
                rows: rows,
              ),
            );
          }
        }
      }
      return DocumentPreviewResult(kind: LibraryDocKind.excel, sheets: sheets);
    } on Object catch (e) {
      return DocumentPreviewResult(kind: LibraryDocKind.excel, error: '$e');
    }
  }

  static Future<DocumentPreviewResult> _parsePptx(String path) async {
    const py = r'''
import sys, json, re, zipfile, xml.etree.ElementTree as ET
path = sys.argv[1]
slides = []
with zipfile.ZipFile(path) as z:
    sfiles = [n for n in z.namelist() if re.match(r'^ppt/slides/slide\d+\.xml$', n)]
    sfiles.sort(key=lambda s: int(re.search(r'(\d+)\.xml$', s).group(1)))
    for idx, sf in enumerate(sfiles[:60], start=1):
        root = ET.fromstring(z.read(sf))
        lines = []
        for p in root.iter():
            if p.tag.endswith('}p'):
                txt = ''.join(t.text or '' for t in p.iter() if t.tag.endswith('}t')).strip()
                if txt:
                    lines.append(txt)
        slides.append({'index': idx, 'lines': lines})
print(json.dumps(slides, ensure_ascii=False))
''';
    try {
      final res = await Process.run('python3', ['-c', py, path]);
      if (res.exitCode != 0) {
        return DocumentPreviewResult(
          kind: LibraryDocKind.powerpoint,
          error: '${res.stderr}'.trim(),
        );
      }
      final decoded = jsonDecode('${res.stdout}');
      final slides = <PptSlidePreview>[];
      if (decoded is List) {
        for (final item in decoded) {
          if (item is Map) {
            slides.add(
              PptSlidePreview(
                index: (item['index'] as num?)?.toInt() ?? slides.length + 1,
                lines: [
                  if (item['lines'] case final List rawLines)
                    for (final l in rawLines) '$l',
                ],
              ),
            );
          }
        }
      }
      return DocumentPreviewResult(
        kind: LibraryDocKind.powerpoint,
        slides: slides,
      );
    } on Object catch (e) {
      return DocumentPreviewResult(
        kind: LibraryDocKind.powerpoint,
        error: '$e',
      );
    }
  }

  static Future<DocumentPreviewResult> _parsePdf(String path) async {
    // Use macOS Spotlight text or pypdf/pypdf2 if available; always allows
    // opening the PDF natively inside Ayte's Embedded WKWebView Browser too.
    const py = r'''
import sys, subprocess
path = sys.argv[1]
try:
    import pypdf
    r = pypdf.PdfReader(path)
    out = [f'Pages: {len(r.pages)}\n']
    for i, page in enumerate(r.pages[:20], 1):
        out.append(f'--- Page {i} ---\n' + (page.extract_text() or '').strip())
    print('\n\n'.join(out)[:30000])
    sys.exit(0)
except Exception:
    pass
res = subprocess.run(['mdls', '-name', 'kMDItemNumberOfPages', '-name', 'kMDItemTitle', '-name', 'kMDItemFSName', path], capture_output=True, text=True)
print((res.stdout or '').strip() + '\n\n(Click "Open in Built-in Browser" above for full native PDF rendering.)')
''';
    return _runTextPython(LibraryDocKind.pdf, py, path);
  }

  static Future<DocumentPreviewResult> _runTextPython(
    LibraryDocKind kind,
    String script,
    String path,
  ) async {
    try {
      final res = await Process.run('python3', ['-c', script, path]);
      if (res.exitCode != 0) {
        return DocumentPreviewResult(
          kind: kind,
          error: '${res.stderr}'.trim(),
        );
      }
      return DocumentPreviewResult(kind: kind, text: '${res.stdout}'.trim());
    } on Object catch (e) {
      return DocumentPreviewResult(kind: kind, error: '$e');
    }
  }
}
