import 'explore_video.dart';

/// One page of search results plus whether another page may exist.
class ExploreSearchPage {
  final List<ExploreVideo> results;
  final bool hasMore;
  final String source;

  const ExploreSearchPage({
    required this.results,
    required this.hasMore,
    this.source = 'server',
  });
}
