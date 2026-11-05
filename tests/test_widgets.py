"""组件契约层：字段优先级、四种详情形态、脏数据丢弃。

这些都是**规范推导 + 实测**得来的：CapyPlayer 组件规范第 5 节列了字段别名表，
happy-capy 的 REST 壳把这些字段原样透出来。上游没有文档，所以每条规则都用
一段字面量 JSON 钉死——规范改别名时，这里会先红。
"""
import pytest

from app import widgets


# ── 组件 ────────────────────────────────────────────────────────────────
def test_provider_keeps_upstream_order_and_drops_bad_ids():
    payload = {'providers': [
        {'id': 'hongguo', 'title': '红果短剧', 'version': '0.1.0',
         'capabilities': ['browse', 'search', 'detail'], 'categories': [{'id': 'short'}]},
        {'id': '../evil', 'title': '坏数据'},
        {'id': '', 'title': '没 id'},
        {'id': 'huangju', 'title': '剧果', 'capabilities': ['browse']},
        {'id': 'hongguo', 'title': '重复的'},
    ]}
    out = widgets.providers(payload)
    assert [p['id'] for p in out] == ['hongguo', 'huangju']
    assert out[0]['title'] == '红果短剧'
    assert out[0]['caps'] == ['browse', 'search', 'detail']
    # 分类标题缺失时回落到 id，别在界面上留一个空白 chip
    assert out[0]['categories'] == [{'id': 'short', 'title': 'short'}]


def test_capabilities_are_advisory_not_a_gate():
    """上游的 capabilities 是未文档化扩展，缺了不能当成「不支持」。"""
    unknown = {'id': 'x', 'caps': []}
    assert widgets.supports(unknown, 'search') is True
    assert widgets.supports({'caps': ['browse']}, 'search') is False
    assert widgets.supports({'caps': ['browse']}, 'browse') is True


def test_unknown_capability_names_are_dropped():
    raw = ['browse', 'BROWSE', 'teleport', 'search', 3, None]
    assert widgets.norm_caps(raw) == ['browse', 'search']


def test_categories_dedupe_by_id():
    raw = [{'id': 'a', 'title': '甲'}, {'id': 'a', 'title': '甲2'}, {'title': '没 id'}]
    assert widgets.categories(raw) == [{'id': 'a', 'title': '甲'}]


# ── 条目：规范第 5.1 节字段优先级 ────────────────────────────────────────
def test_item_field_priority_follows_spec():
    one = widgets.item({
        'id': '7700266048557173784', 'name': '护短妈妈的打脸时刻',
        'posterPath': '/p.jpg', 'poster_url': 'http://a/p.jpg', 'posterUrl': 'http://b/p.jpg',
        'overview': '简介', 'note': '全20集', 'media_type': 'tv',
    })
    assert one['title'] == '护短妈妈的打脸时刻'      # title → name
    assert one['poster'] == 'http://b/p.jpg'        # posterUrl 优先
    assert one['desc'] == '简介'                    # description → overview
    assert one['remark'] == '全20集'                # remark → note
    assert one['mediaType'] == 'tv'                 # mediaType → media_type


def test_item_falls_back_to_lower_priority_poster_keys():
    assert widgets.item({'id': 'a', 'title': 't', 'coverUrl': 'http://c/x.jpg'})['poster'] == \
        'http://c/x.jpg'
    assert widgets.item({'id': 'a', 'title': 't', 'posterPath': '/x.jpg'})['poster'] == '/x.jpg'


def test_item_media_type_whitelist():
    """不认识的 mediaType 留空，别让 'variety' 这种东西漏到前端做分支。"""
    assert widgets.item({'id': 'a', 'title': 't', 'mediaType': 'variety'})['mediaType'] == ''
    assert widgets.item({'id': 'a', 'title': 't'})['mediaType'] == ''


@pytest.mark.parametrize('raw', [
    {'title': '没有 id'},
    {'id': 'a'},
    {'id': 'a', 'title': '   '},
    {'id': '../etc/passwd', 'title': 't'},
    {'id': 'a/b', 'title': 't'},
    {'id': 'a b', 'title': 't'},
    'not-a-dict',
])
def test_dirty_items_are_dropped(raw):
    assert widgets.item(raw) is None


def test_item_accepts_spec_style_ids():
    """规范里的 id 形态很多：红果纯数字、Jable miab-678、蜜桃 video@@…@@missav。"""
    for iid in ('7698294694886788121', 'miab-678', 'video@@abc@@missav', 'a:b.c_d-e'):
        assert widgets.item({'id': iid, 'title': 't'})['id'] == iid


def test_items_keeps_order_and_skips_bad_rows():
    rows = [{'id': 'a', 'title': '甲'}, {'id': '', 'title': '坏'}, {'id': 'b', 'title': '乙'}]
    assert [x['id'] for x in widgets.items(rows)] == ['a', 'b']


# ── 详情形态 ────────────────────────────────────────────────────────────
def test_seasons_form_from_hongguo():
    """红果实测结构：seasons[].episodes[]，每集只有 streamUrl。"""
    payload = {'title': '护短妈妈的打脸时刻', 'mediaType': 'tv', 'posterUrl': 'http://p/1.jpg',
               'seasonCount': 1, 'episodeCount': 2,
               'seasons': [{'id': 'season-1', 'seasonNumber': 1, 'episodes': [
                   {'id': 'ep-1', 'episodeNumber': 1, 'title': '第1集',
                    'streamUrl': 'http://u/api/v1/stream/1'},
                   {'id': 'ep-2', 'episodeNumber': 2, 'title': '第2集',
                    'streamUrl': 'http://u/api/v1/stream/2'},
               ]}]}
    eps = widgets.episodes(payload)
    assert [(e['n'], e['url']) for e in eps] == [
        (1, 'http://u/api/v1/stream/1'), (2, 'http://u/api/v1/stream/2')]


def test_resolve_only_form_from_juuguo():
    """剧果实测结构：只有 mediaUrl + resolveUrl，要二次解析才有直链。"""
    payload = {'seasons': [{'seasonNumber': 1, 'episodes': [
        {'episodeNumber': 1, 'title': '第1集',
         'mediaUrl': 'http://m/1.mp4', 'resolveUrl': 'http://r/1.json'}]}]}
    eps = widgets.episodes(payload)
    assert eps[0]['url'] == 'http://m/1.mp4'
    assert eps[0]['resolve'] == 'http://r/1.json'


def test_flat_episode_items_form():
    """规范允许顶层 episodeItems 扁平数组；以前我们会直接当成「没有剧集」。"""
    payload = {'mediaType': 'tv', 'episodeItems': [
        {'id': 'e1', 'episodeNumber': 1, 'videoUrl': 'http://v/1.m3u8'},
        {'id': 'e2', 'episodeNumber': 2, 'videoUrl': 'http://v/2.m3u8'},
    ]}
    assert [e['n'] for e in widgets.episodes(payload)] == [1, 2]


def test_movie_single_direct_url_is_one_episode():
    """movie 只有一个顶层 videoUrl —— 这是本次补上的关键缺口。"""
    payload = {'title': '某部电影', 'mediaType': 'movie',
               'videoUrl': 'http://v/movie.mp4', 'playerType': 'system'}
    eps = widgets.episodes(payload)
    assert len(eps) == 1
    assert eps[0]['n'] == 1 and eps[0]['url'] == 'http://v/movie.mp4'


def test_top_level_url_does_not_duplicate_first_episode():
    """红果的 tv 详情同时有 seasons 和顶层 videoUrl（= 第 1 集），不能变成两集。"""
    payload = {'videoUrl': 'http://u/api/v1/stream/1', 'seasons': [
        {'seasonNumber': 1, 'episodes': [{'episodeNumber': 1, 'streamUrl': 'http://u/api/v1/stream/1'}]}]}
    assert len(widgets.episodes(payload)) == 1


def test_play_sources_prefers_default_line():
    """规范的多线路写法：找 isDefault，没有就取第一条。"""
    payload = {'mediaType': 'tv', 'episodes': [
        {'episodeNumber': 1, 'playSources': [
            {'id': 'l1', 'videoUrl': 'http://v/line1.m3u8'},
            {'id': 'l2', 'videoUrl': 'http://v/line2.m3u8', 'isDefault': True},
        ]},
    ]}
    assert widgets.episodes(payload)[0]['url'] == 'http://v/line2.m3u8'


def test_play_sources_falls_back_to_first_line():
    payload = {'episodes': [{'episodeNumber': 1,
                             'playSources': [{'videoUrl': 'http://v/a.m3u8'},
                                             {'videoUrl': 'http://v/b.m3u8'}]}]}
    assert widgets.episodes(payload)[0]['url'] == 'http://v/a.m3u8'


def test_episode_without_any_url_is_dropped():
    payload = {'seasons': [{'seasonNumber': 1, 'episodes': [
        {'episodeNumber': 1, 'title': '死按钮'},
        {'episodeNumber': 2, 'streamUrl': 'http://u/2'},
    ]}]}
    assert [e['n'] for e in widgets.episodes(payload)] == [2]


def test_episode_numbers_are_sorted_and_deduped():
    payload = {'seasons': [{'seasonNumber': 1, 'episodes': [
        {'episodeNumber': 3, 'streamUrl': 'http://u/3'},
        {'episodeNumber': 1, 'streamUrl': 'http://u/1'},
        {'episodeNumber': 1, 'streamUrl': 'http://u/1-dup'},
    ]}]}
    eps = widgets.episodes(payload)
    assert [e['n'] for e in eps] == [1, 3]
    assert eps[0]['url'] == 'http://u/1'       # 重复时留先到的


def test_multi_season_numbers_do_not_collide():
    payload = {'seasons': [
        {'seasonNumber': 1, 'episodes': [{'episodeNumber': 1, 'streamUrl': 'http://u/s1e1'}]},
        {'seasonNumber': 2, 'episodes': [{'episodeNumber': 1, 'streamUrl': 'http://u/s2e1'}]},
    ]}
    eps = widgets.episodes(payload)
    assert len(eps) == 2
    assert [e['season'] for e in eps] == [1, 2]


def test_episode_number_out_of_range_falls_back_to_ordinal():
    payload = {'episodes': [{'episodeNumber': 99999, 'streamUrl': 'http://u/1'}]}
    assert widgets.episodes(payload)[0]['n'] == 1


def test_episode_default_title_is_generated():
    payload = {'episodes': [{'episodeNumber': 7, 'streamUrl': 'http://u/7'}]}
    assert widgets.episodes(payload)[0]['title'] == '第7集'


def test_detail_returns_none_when_nothing_playable():
    assert widgets.detail('a', {'title': '空壳', 'seasons': []}) is None
    assert widgets.detail('a', 'not-a-dict') is None


def test_public_detail_never_exposes_direct_urls():
    data = widgets.detail('a', {'title': 't', 'seasons': [
        {'seasonNumber': 1, 'episodes': [{'episodeNumber': 1, 'streamUrl': 'http://secret/1'}]}]})
    out = widgets.public_detail(data)
    assert 'http://secret/1' not in str(out)
    assert out['episodes'] == [{'n': 1, 'title': '第1集'}]


# ── 分页 ────────────────────────────────────────────────────────────────
def test_page_meta_passes_through_upstream_numbers():
    meta = widgets.page_meta({'items': [], 'page': 3, 'pageCount': 1413, 'total': 56496})
    assert meta == {'page': 3, 'pageCount': 1413, 'total': 56496}


def test_page_meta_tolerates_missing_or_garbage():
    assert widgets.page_meta({}, 2) == {'page': 2, 'pageCount': 0, 'total': 0}
    assert widgets.page_meta({'page': 'x', 'pageCount': -5})['pageCount'] == 0


# ── 网络模式 ────────────────────────────────────────────────────────────
DIAG_ENTRY = {
    'target': 'dsd', 'title': '帝果', 'version': '1.0.4',
    'status': 'failed',
    'network_mode': 'direct', 'network_text': '服务器直连',
    'server_check_role': 'required_metadata',
    'impact_hint': '服务器获取内容存在异常，可能影响手机中的列表或详情。',
    'checks': {
        'basic': {'label': '基础检查', 'status': 'passed', 'text': '正常'},
        'server': {'label': '服务器获取内容', 'status': 'failed', 'text': '存在异常'},
        'client': {'label': '手机浏览', 'status': 'not_checked', 'text': '待实际验证'},
        'playback': {'label': '手机播放', 'status': 'not_checked', 'text': '待实际验证'},
    },
    'historical': True,
    'diagnostic_text': '问题定位:\n- 获取首页内容: 未能访问 https://www.dsd.com.se/',
}


def test_network_recognises_the_four_known_modes():
    for mode, label, short in (('direct', '服务器直连', '直连'),
                               ('mobile', '手机端直连', '手机直连'),
                               ('proxy_suggested', '建议海外代理', '需代理'),
                               ('proxy_configured', '海外代理已配置', '已配代理')):
        net = widgets.network({'network_mode': mode})
        assert net['mode'] == mode
        assert net['label'] == label
        assert net['short'] == short
        assert net['unknown'] == ''


def test_network_keeps_unused_status_and_role_vocabulary():
    net = widgets.network(DIAG_ENTRY)
    assert net['status'] == 'failed'
    assert net['role'] == 'required_metadata'
    assert net['checks'] == {'basic': 'passed', 'server': 'failed',
                             'client': 'not_checked', 'playback': 'not_checked'}
    assert net['stale'] is True


def test_network_drops_check_wording_only_status_survives():
    """检测项只留状态：上游的 label/text 是它的措辞，越长的文字越容易夹带地址。"""
    net = widgets.network(DIAG_ENTRY)
    assert set(net['checks'].values()) <= set(widgets.CHECK_STATES)
    assert '存在异常' not in str(net['checks'])
    assert '待实际验证' not in str(net['checks'])
    assert 'label' not in str(net['checks'])


def test_network_never_exposes_addresses_or_accounts():
    """诊断报告里的「问题定位」可能带源站域名，一个字节都不许漏到前端。"""
    net = widgets.network(DIAG_ENTRY)
    blob = str(net)
    assert 'dsd.com.se' not in blob
    assert 'https://' not in blob

    dirty = {'network_mode': 'proxy_configured',
             'network_text': 'http://192.168.31.9:7890',
             'impact_hint': '请检查代理 http://10.0.0.2:7890 与账号 user:pa55@host.net 是否可用'}
    net = widgets.network(dirty)
    blob = str(net)
    assert '192.168' not in blob
    assert '10.0.0.2' not in blob
    assert 'pa55' not in blob
    assert '***' in net['hint']


def test_network_unknown_mode_is_kept_but_never_renamed():
    """上游将来加了新模式：原文留着排障，但绝不冒充已知的四种之一。"""
    net = widgets.network({'network_mode': 'carrier_pigeon', 'network_text': '信鸽直连'})
    assert net['mode'] == ''
    assert net['short'] == ''
    assert net['unknown'] == 'carrier_pigeon'
    assert net['label'] == '信鸽直连'


def test_network_empty_mode_means_upstream_did_not_say():
    """内建源的 network_mode 就是空串 —— 界面该整块不画，而不是画个「未知」。"""
    net = widgets.network({'network_mode': '', 'network_text': '',
                           'status': 'passed', 'checks': {'server': {'status': 'passed'}}})
    assert net['mode'] == '' and net['label'] == '' and net['unknown'] == ''
    assert net['checks'] == {'server': 'passed'}


def test_network_ignores_garbage_states():
    """状态词全是认不出来的：不如整条当没有，别在卡片上显示一个来路不明的词。"""
    assert widgets.network({'status': '???', 'server_check_role': 'nonsense',
                            'checks': {'server': {'status': 'melted'}}}) == {}
    # 有一样能认就留下，认不出的那几样仍然丢掉
    net = widgets.network({'status': '???', 'network_mode': 'direct',
                           'checks': {'server': {'status': 'melted'}}})
    assert net['status'] == '' and net['role'] == ''
    assert net['checks'] == {}
    assert net['mode'] == 'direct'


def test_network_returns_empty_for_unusable_payloads():
    assert widgets.network(None) == {}
    assert widgets.network('x') == {}
    assert widgets.network({}) == {}


def test_nets_indexes_by_provider_and_drops_bad_ids():
    payload = {'results': {'dsd': DIAG_ENTRY, '../evil': DIAG_ENTRY,
                           'yeguo': {'network_mode': 'mobile'},
                           'empty': {'network_mode': '', 'status': ''}}}
    out = widgets.nets(payload)
    assert sorted(out) == ['dsd', 'yeguo']
    assert out['yeguo']['mode'] == 'mobile'


def test_nets_tolerates_missing_results():
    assert widgets.nets({}) == {}
    assert widgets.nets({'results': []}) == {}
    assert widgets.nets('nope') == {}


# ── 组件目录（components/catalog）────────────────────────────────────────
# 上游两份清单说的不是一件事：/providers 只有通用契约，/components/catalog 才是全量。
# 三个内建组件（bilibili / huangguo / missav）就在差集里 —— 它们的 install 包里
# 只有 widget.js，没有 provider.so，抓取跑在手机端，服务端拿不到片单。
def test_component_recognises_generic_provider_contract():
    one = widgets.component({
        'id': 'hongguo', 'title': '红果短剧', 'version': '0.3.15',
        'backendCapabilities': ['provider:hongguo@1'], 'backendType': 'so-worker',
        'artifacts': {'provider': 'provider.so', 'widget': 'widget.js'}})
    assert one['provider'] == 'hongguo'
    assert one['provider_so'] is True
    assert one['builtin'] if 'builtin' in one else True   # 归一化层不判 builtin，交由上层


def test_component_without_provider_cap_is_the_builtin_case():
    """没有 `provider:<id>@1` 就是接不上的那一类 —— 这是唯一的判据。"""
    for caps in (['widget:universal@1'],
                 ['huangguo:cover@1', 'huangguo:routes@1', 'widget:access-bootstrap@1'],
                 ['discovery:missav@1', 'missav:prepare@1', 'video:proxy@1']):
        one = widgets.component({'id': 'x', 'backendCapabilities': caps,
                                 'backendType': 'builtin',
                                 'artifacts': {'widget': 'widget.js'}})
        assert one['provider'] == ''
        assert one['provider_so'] is False
        assert one['caps'] == caps        # 原样留着，排查时全靠它


def test_component_prefers_top_level_title_over_install_record():
    """顶层 title 才是中文名（bilibili → 哔哩哔哩），`local` 里那份是安装记录原文。"""
    one = widgets.component({'id': 'bilibili', 'title': '哔哩哔哩',
                             'local': {'title': 'bilibili'}, 'backendCapabilities': []})
    assert one['title'] == '哔哩哔哩'
    # 顶层缺了才退到 local，再缺就用 id —— 卡片上绝不能是空白
    two = widgets.component({'id': 'x', 'local': {'title': '某组件'}})
    assert two['title'] == '某组件'
    assert widgets.component({'id': 'y'})['title'] == 'y'


def test_component_rejects_ids_that_would_escape_the_path():
    for bad in ('../evil', 'a/b', '', 'x' * 40):
        assert widgets.component({'id': bad, 'title': 't'}) is None
    assert widgets.component('nope') is None
    assert widgets.component({'title': '没有 id'}) is None


def test_components_keeps_upstream_order_and_drops_duplicates():
    payload = {'components': [
        {'id': 'b', 'title': 'B'}, {'id': 'a', 'title': 'A'},
        {'id': 'b', 'title': 'B 重复'}, {'id': '../evil', 'title': '脏'}]}
    out = widgets.components(payload)
    assert [x['id'] for x in out] == ['b', 'a']
    assert out[0]['title'] == 'B'


def test_components_tolerates_unusable_payloads():
    assert widgets.components(None) == []
    assert widgets.components({'components': 'x'}) == []
    assert widgets.components({}) == []
