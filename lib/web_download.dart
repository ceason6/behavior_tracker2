// Web implementation: triggers a browser file download.
import 'dart:html' as html;

void downloadTextFile(String filename, String content, String mimeType) {
  final blob = html.Blob(<Object>[content], mimeType);
  final url = html.Url.createObjectUrlFromBlob(blob);
  final anchor = html.AnchorElement(href: url)..download = filename;
  html.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
  html.Url.revokeObjectUrl(url);
}
