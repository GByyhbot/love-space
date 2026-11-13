/// composer 本地暂存序列化单测（段二 A）：
/// toJson/fromJson 往返无损；uploadedId 空缺与恢复语义；isEmpty 口径。
import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/features/timeline/composer_store.dart';

void main() {
  test('ComposerStore round-trip：字段逐一无损', () {
    const store = ComposerStore(
      title: '标题',
      content: '正文',
      date: '2026-11-13',
      album: 'album-id-1',
      postClientId: 'post-uuid',
      draftClientId: 'draft-uuid',
      media: [
        StoredMedia(path: '/tmp/a.jpg', name: 'a.jpg'),
        StoredMedia(path: '', name: 'media:m1', uploadedId: 'm1'),
      ],
    );
    final restored = ComposerStore.fromJson(store.toJson());
    expect(restored.title, '标题');
    expect(restored.content, '正文');
    expect(restored.date, '2026-11-13');
    expect(restored.album, 'album-id-1');
    expect(restored.postClientId, 'post-uuid');
    expect(restored.draftClientId, 'draft-uuid');
    expect(restored.media.length, 2);
    expect(restored.media[0].path, '/tmp/a.jpg');
    expect(restored.media[0].uploadedId, isNull);
    expect(restored.media[1].uploadedId, 'm1');
  });

  test('暂存恢复：null 字段安全回空（未传完媒体 uploadedId 为空）', () {
    final restored = ComposerStore.fromJson({
      'title': 't',
      'content': '',
      'date': '2026-01-02',
      'media': [
        {'path': '/tmp/b.m4a', 'name': 'b.m4a'},
      ],
    });
    expect(restored.album, isNull);
    expect(restored.postClientId, isNull);
    expect(restored.draftClientId, isNull);
    expect(restored.media.single.uploadedId, isNull);
    expect(restored.isEmpty, isFalse);
  });

  test('isEmpty：全空表单为空；任一字段有值即非空', () {
    expect(const ComposerStore().isEmpty, isTrue);
    const withTitle = ComposerStore(title: 'x');
    expect(withTitle.isEmpty, isFalse);
    const withMedia = ComposerStore(media: [StoredMedia(path: 'p', name: 'n')]);
    expect(withMedia.isEmpty, isFalse);
    const withAlbum = ComposerStore(album: 'a');
    expect(withAlbum.isEmpty, isFalse);
  });

  test('album 为空串时不落盘 album 键（暂不分类 = 不带字段）', () {
    const store = ComposerStore(album: '');
    final json = store.toJson();
    expect(json.containsKey('album'), isFalse);
  });
}
