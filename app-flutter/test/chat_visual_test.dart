/* 贴纸/媒体渲染判定单测（段二 · chatVisualOf 纯函数）：
   ④ 贴纸 body 两形态渲染参数（内置包 sticker path vs 自定义表情 media mid）、
      媒体按 mime 分流（图片/视频/语音/未知附件）、引用/撤回优先级。 */
import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/core/chat/chat_models.dart';

ChatRecord rec(Map<String, dynamic> body, List<Map<String, dynamic>> media) =>
    ChatRecord.fromJson({
      'id': 'v1', 'kind': 'chat', 'author': 'a1',
      'body': body, 'created': 1.0, 'updated': 1.0, 'client_id': '',
      'media': media,
    });

void main() {
  test('内置包贴纸：webm → 视频（公开静态路径，无需 Cookie）', () {
    final v = chatVisualOf(rec({
      'content': '', 'media': [],
      'sticker': '/static/stickers/musicfuckdancer3/12.webm',
    }, []));
    final s = v.sticker!;
    expect(s.path, '/static/stickers/musicfuckdancer3/12.webm');
    expect(s.mid, isNull);
    expect(s.isVideo, true);
    expect(v.textLines, isEmpty);
  });

  test('内置包贴纸：webp → 静态图', () {
    final v = chatVisualOf(rec({
      'content': '', 'media': [],
      'sticker': '/static/stickers/lolitax/7.webp',
    }, []));
    expect(v.sticker!.isVideo, false);
    expect(v.sticker!.path, '/static/stickers/lolitax/7.webp');
  });

  test('自定义表情：单媒体 image/webp 且无文本 → 贴纸化（媒体 mid，需 Cookie）', () {
    final v = chatVisualOf(rec(
        {'content': '', 'media': ['m1']},
        [
          {'id': 'm1', 'name': 's.webp', 'mime': 'image/webp', 'size': 1,
           'status': 'ready', 'preview': null},
        ]));
    final s = v.sticker!;
    expect(s.mid, 'm1');
    expect(s.path, isNull);
    expect(s.isVideo, false);
  });

  test('自定义表情：单媒体 video/webm 且无文本 → 贴纸视频', () {
    final v = chatVisualOf(rec(
        {'content': '', 'media': ['m2']},
        [
          {'id': 'm2', 'name': 's.webm', 'mime': 'video/webm', 'size': 1,
           'status': 'ready', 'preview': null},
        ]));
    expect(v.sticker!.mid, 'm2');
    expect(v.sticker!.isVideo, true);
  });

  test('普通图片（image/png）不走贴纸化 → imageMids', () {
    final v = chatVisualOf(rec(
        {'content': '', 'media': ['m3']},
        [
          {'id': 'm3', 'name': 'a.png', 'mime': 'image/png', 'size': 1,
           'status': 'ready', 'preview': null},
        ]));
    expect(v.sticker, isNull);
    expect(v.imageMids, ['m3']);
  });

  test('两张 webp 不贴纸化（单媒体才贴纸化）', () {
    final v = chatVisualOf(rec(
        {'content': '', 'media': ['a', 'b']},
        [
          {'id': 'a', 'name': '1.webp', 'mime': 'image/webp', 'size': 1, 'status': 'ready', 'preview': null},
          {'id': 'b', 'name': '2.webp', 'mime': 'image/webp', 'size': 1, 'status': 'ready', 'preview': null},
        ]));
    expect(v.sticker, isNull);
    expect(v.imageMids, hasLength(2));
  });

  test('语音 → voiceMids（voice chip）；带文本时文本与语音并存', () {
    final voice = chatVisualOf(rec(
        {'content': '', 'media': ['v1']},
        [
          {'id': 'v1', 'name': 'v.m4a', 'mime': 'audio/mp4', 'size': 1, 'status': 'ready', 'preview': null},
        ]));
    expect(voice.voiceMids, ['v1']);
    expect(voice.sticker, isNull);

    final withText = chatVisualOf(rec(
        {'content': '听听', 'media': ['v1']},
        [
          {'id': 'v1', 'name': 'v.m4a', 'mime': 'audio/mp4', 'size': 1, 'status': 'ready', 'preview': null},
        ]));
    expect(withText.textLines, ['听听']);
    expect(withText.voiceMids, ['v1']);
  });

  test('视频 → videoMids；未知 mime → [附件] 占位文本行', () {
    final v = chatVisualOf(rec(
        {'content': '', 'media': ['m4', 'm5']},
        [
          {'id': 'm4', 'name': 'x.mp4', 'mime': 'video/mp4', 'size': 1, 'status': 'ready', 'preview': null},
          {'id': 'm5', 'name': 'y.bin', 'mime': 'application/octet-stream', 'size': 1, 'status': 'ready', 'preview': null},
        ]));
    expect(v.videoMids, ['m4']);
    expect(v.textLines, ['[附件]']);
  });

  test('引用优先于贴纸化：单张 webp + reply_to → 图片 + [引用] 行', () {
    final v = chatVisualOf(rec(
        {'content': '', 'media': ['m1'], 'reply_to': {'id': 'r0', 'text': '原话'}},
        [
          {'id': 'm1', 'name': 's.webp', 'mime': 'image/webp', 'size': 1, 'status': 'ready', 'preview': null},
        ]));
    expect(v.sticker, isNull);
    expect(v.imageMids, ['m1']);
    expect(v.textLines, ['[引用] 原话']);
  });

  test('撤回优先：recalled → 全空（页面单独渲染撤回行）', () {
    final v = chatVisualOf(rec(
        {'content': '', 'media': ['m1'], 'recalled': true, 'sticker': '/static/stickers/lolitax/7.webp'},
        []));
    expect(v.isEmpty, true);
  });

  test('文本消息：内容进 textLines（与段一 placeholderLines 口径一致）', () {
    final v = chatVisualOf(rec({'content': '你好呀', 'media': []}, []));
    expect(v.textLines, ['你好呀']);
    expect(v.isEmpty, false);
  });
}
