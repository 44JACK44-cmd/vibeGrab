import 'package:flutter_test/flutter_test.dart';
import 'package:vibegrab/data/models/download_task.dart';

void main() {
  DownloadTask task({double progress = 0, int? total}) => DownloadTask(
        id: 't1',
        url: 'https://example.com/v',
        title: 'Video',
        formatId: '18',
        progress: progress,
        totalBytes: total,
        createdAt: '2026-01-01T00:00:00Z',
      );

  test('progressFormatted renders a whole percentage, never a raw float', () {
    expect(task(progress: 0).progressFormatted, '0%');
    expect(task(progress: 0.224).progressFormatted, '22%');
    expect(task(progress: 1).progressFormatted, '100%');
  });

  test('sizeFormatted uses KB/MB with one decimal', () {
    expect(task(total: (22.4 * 1024 * 1024).round()).sizeFormatted, '22.4 MB');
    expect(task(total: 512 * 1024).sizeFormatted, '512 KB');
    expect(task().sizeFormatted, '');
  });
}
