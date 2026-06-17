// Non-web fallback. The pilot runs on the web build; on other platforms the
// caller guards with kIsWeb and shows a message instead of calling this.
void downloadTextFile(String filename, String content, String mimeType) {
  throw UnsupportedError('File download is only supported on the web build.');
}
