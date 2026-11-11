/* 模型解析单测：对齐服务端 records kind='chat' 的真实 JSON 形态
   （api-samples/03-records.md + api-samples/05-realtime-aggregate.md 实测样本）。 */
import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/core/chat/chat_models.dart';

void main() {
  test('纯文本聊天记录解析（阶段 0 实测样本形态）', () {
    final r = ChatRecord.fromJson({
      'id': '12c1256a25164af0b3d61f854a0fe3e3',
      'kind': 'chat',
      'author': '823feeb85680412d9f23719e5e481c92',
      'body': {'content': '聊天样本消息', 'media': []},
      'created': 1794358046.7493746,
      'updated': 1794358046.7493746,
      'deleted': null,
      'published': 1794358046.7493746,
      'client_id': 's0-c',
      'likes': [],
      'comments': [],
      'media': [],
    });
    expect(r.id, '12c1256a25164af0b3d61f854a0fe3e3');
    expect(r.author, '823feeb85680412d9f23719e5e481c92');
    expect(r.created, 1794358046.7493746);
    expect(r.clientId, 's0-c');
    expect(r.body.content, '聊天样本消息');
    expect(r.body.recalled, false);
    expect(r.placeholderLines(), ['聊天样本消息']);
  });

  test('媒体消息解析（preview 为 null 容错；占位不崩）', () {
    final r = ChatRecord.fromJson({
      'id': '81385ff2d7cf4a56aab6ebb285b314bd',
      'kind': 'chat',
      'author': '823feeb85680412d9f23719e5e481c92',
      'body': {'content': '看图', 'media': ['93e941af5961478bb463e69e1f184311']},
      'created': 1794358036.8185856,
      'updated': 1794358036.8185856,
      'deleted': null,
      'published': 1794358036.8185856,
      'client_id': 'img-1794358036800',
      'likes': [],
      'comments': [],
      'media': [
        {'id': '93e941af5961478bb463e69e1f184311', 'name': 'e2e.png',
         'mime': 'image/png', 'size': 186, 'status': 'pending', 'preview': null},
      ],
    });
    expect(r.body.mediaIds, ['93e941af5961478bb463e69e1f184311']);
    expect(r.media.single.status, 'pending');
    expect(r.media.single.preview, '');
    // 段一渲染边界：文本 + 中性占位，绝不崩
    expect(r.placeholderLines(), ['看图', '[图片]']);
  });

  test('撤回态解析（服务端 recall 后 body.recalled=true 且 content 清空）', () {
    final r = ChatRecord.fromJson({
      'id': 'r1', 'kind': 'chat', 'author': 'a1',
      'body': {'recalled': true, 'content': ''},
      'created': 1.0, 'updated': 2.0, 'client_id': null, 'media': [],
    });
    expect(r.body.recalled, true);
    expect(r.body.content, '');
    expect(r.placeholderLines(), isEmpty);
  });

  test('引用/贴纸/歌曲/位置解析与占位（段一不渲染媒体但不崩）', () {
    final r = ChatRecord.fromJson({
      'id': 'x1', 'kind': 'chat', 'author': 'a1',
      'body': {
        'content': '',
        'media': [],
        'reply_to': {'id': 'r0', 'text': '之前那句话'},
        'sticker': '/static/stickers/daily/1.webp',
        'song': {'title': '告白气球', 'artist': '周杰伦', 'mid': '', 'src': '',
                 'art': '', 'dur': 30.0},
        'location': {'lat': 31.2304, 'lng': 121.4737},
        'pinned': true,
      },
      'created': 1.0, 'updated': 1.0, 'client_id': '', 'media': [],
    });
    expect(r.body.replyToId, 'r0');
    expect(r.body.replyToText, '之前那句话');
    expect(r.body.pinned, true);
    final lines = r.placeholderLines();
    expect(lines, contains('[引用] 之前那句话'));
    expect(lines, contains('[贴纸]'));
    expect(lines, contains('[歌曲] 告白气球'));
    expect(lines, contains('[位置]'));
  });

  test('畸形数据容错：null/缺字段不抛异常', () {
    final r = ChatRecord.fromJson({
      'id': 'y1', 'kind': 'chat', 'author': 'a1',
      'body': null, 'created': null, 'updated': null, 'client_id': null,
      'media': null,
    });
    expect(r.id, 'y1');
    expect(r.created, 0);
    expect(r.body.content, '');
    expect(r.placeholderLines(), isEmpty);
  });

  test('toJson/fromJson 往返一致（drift 缓存序列化依据）', () {
    final r = ChatRecord.fromJson({
      'id': 'z1', 'kind': 'chat', 'author': 'a1',
      'body': {'content': 'hi', 'media': [], 'pinned': true},
      'created': 123.5, 'updated': 124.5, 'client_id': 'c1',
      'media': [
        {'id': 'm1', 'name': 'a.png', 'mime': 'image/png', 'size': 1,
         'status': 'ready', 'preview': 'a.preview.jpg'},
      ],
    });
    final back = ChatRecord.fromJson(r.toJson());
    expect(back.toJson(), r.toJson());
    expect(back.rendersSameAs(r), true);
  });
}
