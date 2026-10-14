class FileUtils {
  /// Guesses the mime type from the file extension.
  static String mimeFor(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();
    if (ext == 'jpg' || ext == 'jpeg') return 'image/jpeg';
    if (ext == 'png') return 'image/png';
    if (ext == 'pdf') return 'application/pdf';
    return 'application/octet-stream';
  }

  static bool isImage(String mimeType) => mimeType.startsWith('image/');
}
