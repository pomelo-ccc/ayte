import 'package:path/path.dart' as p;

import '../../browser/embedded/embedded_browser_controller.dart';
import '../../browser/embedded/embedded_browser_settings.dart';
import '../../ide/file_views.dart';
import '../../l10n/l10n.dart';

/// A web page on this machine: opens in Ayte's built-in browser when HTML
/// embedded preview is enabled, or in the system browser otherwise.
final webPageOpener = FileOpener(
  id: 'webPage',
  matches: (path) =>
      const {'.html', '.htm'}.contains(p.extension(path).toLowerCase()),
  label: (context) => context.l10n.fileLinkOpenInBrowser,
  open: (path) => EmbeddedBrowserController.instance.openLink(
    Uri.file(path).toString(),
    source: LinkSource.editor,
  ),
);
