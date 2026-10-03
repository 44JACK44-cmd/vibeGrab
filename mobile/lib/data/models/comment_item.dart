class CommentItem {
  final String author;
  final String text;
  final String? avatar;
  final String? published;
  final String? likes;
  final String? replies;
  final bool verified;
  final String? pinnedText;

  const CommentItem({
    required this.author,
    required this.text,
    this.avatar,
    this.published,
    this.likes,
    this.replies,
    this.verified = false,
    this.pinnedText,
  });

  factory CommentItem.fromJson(Map<String, dynamic> json) {
    return CommentItem(
      author: json['author'] ?? '',
      text: json['text'] ?? '',
      avatar: json['avatar'],
      published: json['published'],
      likes: json['likes'],
      replies: json['replies'],
      verified: json['verified'] == true,
      pinnedText: json['pinned_text'],
    );
  }
}

class CommentsPage {
  final List<CommentItem> items;
  final String? nextToken;

  const CommentsPage({required this.items, this.nextToken});
}
