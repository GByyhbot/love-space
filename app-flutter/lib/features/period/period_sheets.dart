/// 日记录 9 字段底部弹层（条目 8 · 段 8-B）：逐字移植
/// `period.js:343-483` 的 periodLogSheet / periodChoiceSheet / periodMultiSheet /
/// periodNumberSheet / periodSexSheet。
///
/// 九项：flow / color / pain / sex / symptoms / mood / weight / discharge / temp
/// （`PERIOD_LOG_FIELDS :28`）+ `content` 日记行（`:313`）。
/// · 单选（`flow/color/pain/mood`）：点一下就存并关；点同一项再传 `null` 清除（`:406`）；
/// · `discharge`：专属列表，点一下即存（`:476-482`）；
/// · `symptoms`：多选，「没有症状」与具体症状互斥（`:419`），≤20 去重；
/// · `weight/temp`：自绘数字键盘 + 范围校验（20–300 / 30–45，`:445`）；
/// · `sex`：同房子弹层，最多 8 次（`:386`）、措施多选、时间滚轮，
///   确定 → `periodSaveDay(day,{sex:[{t,w}]})`（`:371`）；
/// · 老数据纯编号数组 `[2,4]` 由 [periodSexEntries] 归一（`:318-322`）。
///
/// 保存走 [planSaveDay]（`:59-70` 语义）+ `executePlan`（7-C 错误通道）：
/// **失败不发成功通知 / 不 pop / 输入保留 / 不自动重试**，服务端 detail 原文
/// 顶部通知 + 弹层内联双呈现。`client_id` 由本 State 的 initState 生成一次复用。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart' as api;
import '../chat/chat_toast.dart' show ChatToastTone, chatToastProvider;
import 'period_actions.dart';
import 'period_controller.dart';
import 'period_meta.dart';

/// 打开某天的某个字段弹层。
Future<void> showPeriodLogSheet(
  BuildContext context, {
  required String field,
  required String day,
  required String today,
  required String nowTime,
}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => PeriodLogSheet(
        field: field,
        day: day,
        today: today,
        nowTime: nowTime,
      ),
    );

String _pad2(int v) => v.toString().padLeft(2, '0');

/// 弹层标题（Web `openModal` 第一个参数）。
String periodSheetTitle(String field) {
  switch (field) {
    case 'content':
      return '这一天的日记';
    case 'flow':
      return '流量';
    case 'color':
      return '颜色';
    case 'pain':
      return '痛经';
    case 'mood':
      return '心情';
    case 'sex':
      return '爱爱';
    case 'symptoms':
      return '症状';
    case 'weight':
      return '体重';
    case 'temp':
      return '体温';
    case 'discharge':
      return '白带';
    default:
      return '记这一天';
  }
}

/// 一次同房的可编辑草稿。
class _SexDraft {
  _SexDraft(this.t, this.w);

  String t;
  Set<int> w;

  Map<String, dynamic> toJson() => <String, dynamic>{
        't': t,
        'w': w.toList()..sort(),
      };
}

/// 单个选项（对齐 `psOption :397-399`）。
class _Option {
  const _Option(this.value, this.label, this.visual, {this.swatch});

  final int value;
  final String label;
  final String visual;
  final Color? swatch;
}

class PeriodLogSheet extends ConsumerStatefulWidget {
  const PeriodLogSheet({
    super.key,
    required this.field,
    required this.day,
    required this.today,
    required this.nowTime,
  });

  final String field;
  final String day;
  final String today;
  final String nowTime;

  @override
  ConsumerState<PeriodLogSheet> createState() => _PeriodLogSheetState();
}

class _PeriodLogSheetState extends ConsumerState<PeriodLogSheet> {
  /// 🔴 7-C：只在 initState 生成一次，失败重试复用同一个值。
  late final String _clientId;
  late final Map<String, dynamic> _body;
  late final TextEditingController _contentCtrl;
  late final Set<String> _chosenSymptoms;
  late final List<_SexDraft> _sexEntries;
  late final FixedExtentScrollController _hourCtrl;
  late final FixedExtentScrollController _minuteCtrl;

  int _sexCur = 0;
  String _numBuf = '';
  bool _saving = false;
  bool _syncingWheel = false;
  String? _inlineError;

  static const List<String> _hours = <String>[
    '00', '01', '02', '03', '04', '05', '06', '07',
    '08', '09', '10', '11', '12', '13', '14', '15',
    '16', '17', '18', '19', '20', '21', '22', '23',
  ];
  static final List<String> _minutes = <String>[
    for (var i = 0; i < 60; i++) _pad2(i),
  ];

  @override
  void initState() {
    super.initState();
    _clientId = api.newClientId();
    final rows = ref.read(periodControllerProvider.notifier).periodRows;
    _body = Map<String, dynamic>.from(periodDayLogOf(rows, widget.day));
    _contentCtrl =
        TextEditingController(text: (_body['content'] ?? '').toString());
    _chosenSymptoms = <String>{
      if (_body['symptoms'] is List)
        for (final s in (_body['symptoms'] as List)) s.toString(),
    };

    final existing = periodSexEntries(_body);
    _sexEntries = existing.isNotEmpty
        ? existing
            .map((e) => _SexDraft(e.t, e.w.toSet()))
            .toList()
        : <_SexDraft>[_SexDraft(widget.nowTime, <int>{})];
    final first = _parseTime(_sexEntries.first.t);
    _hourCtrl = FixedExtentScrollController(initialItem: first.$1);
    _minuteCtrl = FixedExtentScrollController(initialItem: first.$2);
    if (widget.field == 'weight' || widget.field == 'temp') {
      final cur = _body[widget.field];
      _numBuf = cur == null ? '' : cur.toString();
    }
  }

  @override
  void dispose() {
    _contentCtrl.dispose();
    _hourCtrl.dispose();
    _minuteCtrl.dispose();
    super.dispose();
  }

  (int, int) _parseTime(String raw) {
    final p = raw.split(':');
    final h = p.isNotEmpty ? (int.tryParse(p[0]) ?? 0) : 0;
    final m = p.length > 1 ? (int.tryParse(p[1]) ?? 0) : 0;
    return (h.clamp(0, 23), m.clamp(0, 59));
  }

  /// 统一保存：`planSaveDay`（Web `:59-70`）+ `executePlan`（7-C 通道）。
  Future<void> _save(Map<String, dynamic> patch) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _inlineError = null;
    });
    final ctrl = ref.read(periodControllerProvider.notifier);
    final plan = planSaveDay(
      records: ctrl.periodRows,
      day: widget.day,
      patch: patch,
      clientId: _clientId,
    );
    final err = await ctrl.executePlan(plan);
    if (!mounted) return;
    if (err != null) {
      // 🔴 失败：原文双呈现、不 pop、输入保留、不自动重试、不发成功通知。
      setState(() {
        _saving = false;
        _inlineError = err;
      });
      ref
          .read(chatToastProvider.notifier)
          .show('保存失败：$err', tone: ChatToastTone.error);
      return;
    }
    // Web `closeModal()`；periodSaveDay 成功不发 toast（静默刷新）。
    Navigator.of(context).pop();
  }

  List<_Option> _choiceOptions() {
    switch (widget.field) {
      case 'flow':
        return <_Option>[
          for (final e in periodFlow.entries)
            _Option(e.key, e.value, '🩸'),
        ];
      case 'color':
        return <_Option>[
          for (final e in periodColor.entries)
            _Option(e.key, e.value[0], '',
                swatch: Color(
                    int.parse(e.value[1].replaceFirst('#', '0xFF')))),
        ];
      case 'pain':
        return <_Option>[
          for (final e in periodPain.entries)
            _Option(e.key, e.value[0], e.value[1]),
        ];
      case 'mood':
        return <_Option>[
          for (var i = 0; i < periodMoods.length; i++)
            _Option(i + 1, periodMoods[i][1], periodMoods[i][0]),
        ];
      default:
        return const <_Option>[];
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 12,
          bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                Expanded(
                    child: Text(periodSheetTitle(widget.field),
                        style: theme.textTheme.titleMedium)),
                Text(widget.day == widget.today ? '今天' : widget.day,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: cs.outline)),
              ]),
              const SizedBox(height: 12),
              _buildBody(theme, cs),
              if (_inlineError != null) ...[
                const SizedBox(height: 8),
                Text(_inlineError!,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: cs.error)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(ThemeData theme, ColorScheme cs) {
    switch (widget.field) {
      case 'content':
        return _contentSheet(theme, cs);
      case 'discharge':
        return _dischargeSheet(theme, cs);
      case 'symptoms':
        return _symptomsSheet(theme, cs);
      case 'weight':
      case 'temp':
        return _numberSheet(theme, cs);
      case 'sex':
        return _sexSheet(theme, cs);
      default:
        return _choiceSheet(theme, cs);
    }
  }

  // ── 单选（periodChoiceSheet :400-409） ────────────────────────────────
  Widget _choiceSheet(ThemeData theme, ColorScheme cs) {
    final options = _choiceOptions();
    final cur = _body[widget.field];
    return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _optionGrid(options, cur, theme, cs, onTap: (o) {
            final same = cur != null && cur.toString() == o.value.toString();
            return _save(<String, dynamic>{
              widget.field: same ? null : o.value,
            });
          }),
          const SizedBox(height: 10),
          Text('选一下就直接保存；再点一次同一项就是清除。',
              style: theme.textTheme.bodySmall?.copyWith(color: cs.outline)),
          const SizedBox(height: 8),
          TextButton(
              onPressed: _saving ? null : () => Navigator.of(context).pop(),
              child: const Text('取消')),
        ]);
  }

  Widget _optionGrid(
    List<_Option> options,
    Object? cur,
    ThemeData theme,
    ColorScheme cs, {
    required Future<void> Function(_Option) onTap,
    bool Function(_Option)? selected,
    bool multi = false,
  }) {
    bool isOn(_Option o) =>
        selected != null ? selected(o) : cur?.toString() == o.value.toString();
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 5, childAspectRatio: 0.82, mainAxisSpacing: 6,
          crossAxisSpacing: 6),
      itemCount: options.length,
      itemBuilder: (ctx, i) {
        final o = options[i];
        final on = isOn(o);
        return Material(
          key: Key('ps-opt-${o.value}'),
          color: on ? cs.primaryContainer : cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: _saving ? null : () => onTap(o),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: on ? cs.primary : cs.outlineVariant,
                    width: on ? 2 : 1),
              ),
              padding: const EdgeInsets.all(4),
              child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _optionVisual(o, theme, cs),
                    const SizedBox(height: 3),
                    Text(o.label,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall),
                    if (on)
                      Icon(multi ? Icons.check_rounded : Icons.circle,
                          key: Key('ps-on-${o.value}'),
                          size: 10,
                          color: cs.primary),
                  ]),
            ),
          ),
        );
      },
    );
  }

  Widget _optionVisual(_Option o, ThemeData theme, ColorScheme cs) {
    if (o.swatch != null) {
      return Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(color: o.swatch, shape: BoxShape.circle));
    }
    if (widget.field == 'flow') {
      final size = (7 + o.value * 3).toDouble();
      return Container(
          width: size,
          height: size,
          decoration: const BoxDecoration(
              color: Color(0xFFEF3F68), shape: BoxShape.circle));
    }
    return Text(o.visual, style: const TextStyle(fontSize: 20));
  }

  // ── 白带（periodLogSheet :476-482） ──────────────────────────────────
  Widget _dischargeSheet(ThemeData theme, ColorScheme cs) {
    final cur = _body['discharge'];
    return Column(mainAxisSize: MainAxisSize.min, children: [
      for (final e in periodDischarge.entries)
        ListTile(
          leading: const Text('💧', style: TextStyle(fontSize: 20)),
          title: Text(e.value[0]),
          subtitle: Text(e.value[1], style: theme.textTheme.bodySmall),
          trailing: cur?.toString() == e.key.toString()
              ? Icon(Icons.radio_button_checked, color: cs.primary)
              : const Icon(Icons.radio_button_unchecked),
          onTap: _saving
              ? null
              : () => _save(<String, dynamic>{'discharge': e.key}),
        ),
      TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('取消')),
    ]);
  }

  // ── 症状多选（periodMultiSheet :410-428） ────────────────────────────
  Widget _symptomsSheet(ThemeData theme, ColorScheme cs) {
    // 用名称作 value 对照（periodMultiSheet 的 data-pick 是名称字符串）。
    bool isOn(String name) => _chosenSymptoms.contains(name);

    void toggle(String name) {
      setState(() {
        final turningOn = !_chosenSymptoms.contains(name);
        if (turningOn) {
          // `:419` 「没有症状」与具体症状互斥。
          if (name == '没有症状') {
            _chosenSymptoms.removeWhere((s) => s != '没有症状');
          } else {
            _chosenSymptoms.remove('没有症状');
          }
          _chosenSymptoms.add(name);
        } else {
          _chosenSymptoms.remove(name);
        }
      });
    }

    return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('身体症状', style: theme.textTheme.labelLarge),
          const SizedBox(height: 6),
          _symptomGrid(periodBodySymptoms, isOn, toggle, theme, cs),
          const SizedBox(height: 10),
          Text('阴道分泌物', style: theme.textTheme.labelLarge),
          const SizedBox(height: 6),
          _symptomGrid(periodSecretion, isOn, toggle, theme, cs),
          const SizedBox(height: 12),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            TextButton(
                onPressed: _saving ? null : () => Navigator.of(context).pop(),
                child: const Text('取消')),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _saving
                  ? null
                  : () => _save(<String, dynamic>{
                        'symptoms': periodSymptoms
                            .where(_chosenSymptoms.contains)
                            .toList(),
                      }),
              child: const Text('确定'),
            ),
          ]),
        ]);
  }

  Widget _symptomGrid(
    List<List<String>> src,
    bool Function(String) isOn,
    void Function(String) toggle,
    ThemeData theme,
    ColorScheme cs,
  ) =>
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final pair in src)
            FilterChip(
              avatar: Text(pair[1], style: const TextStyle(fontSize: 13)),
              label: Text(pair[0], style: const TextStyle(fontSize: 12)),
              selected: isOn(pair[0]),
              onSelected: _saving ? null : (_) => toggle(pair[0]),
            ),
        ],
      );

  // ── 体重 / 体温（periodNumberSheet :430-450） ────────────────────────
  Widget _numberSheet(ThemeData theme, ColorScheme cs) {
    final isWeight = widget.field == 'weight';
    final unit = isWeight ? '公斤' : '℃';
    final low = isWeight ? 20 : 30;
    final high = isWeight ? 300 : 45;
    final title = periodSheetTitle(widget.field);
    return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(vertical: 18),
            alignment: Alignment.center,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(_numBuf.isEmpty ? '0' : _numBuf,
                  style: theme.textTheme.headlineMedium),
              const SizedBox(width: 8),
              Text(unit, style: theme.textTheme.bodyMedium),
            ]),
          ),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3, childAspectRatio: 1.8),
            itemCount: 12,
            itemBuilder: (ctx, i) {
              const keys = <String>[
                '1', '2', '3', '4', '5', '6', '7', '8', '9', '.', '0', 'del',
              ];
              final k = keys[i];
              return Padding(
                padding: const EdgeInsets.all(3),
                child: OutlinedButton(
                  onPressed: _saving ? null : () => _onNumKey(k),
                  child: Text(k == 'del' ? '⌫' : k,
                      style: const TextStyle(fontSize: 18)),
                ),
              );
            },
          ),
          const SizedBox(height: 10),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            TextButton(
                onPressed: _saving ? null : () => Navigator.of(context).pop(),
                child: const Text('取消')),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _saving
                  ? null
                  : () => _submitNumber(low, high, title),
              child: const Text('确定'),
            ),
          ]),
        ]);
  }

  /// `periodNumberSheet :435-442` 自绘数字键盘（不弹系统键盘）。
  void _onNumKey(String k) {
    setState(() {
      if (k == 'del') {
        if (_numBuf.isNotEmpty) {
          _numBuf = _numBuf.substring(0, _numBuf.length - 1);
        }
      } else if (k == '.') {
        if (!_numBuf.contains('.')) {
          final prefix = _numBuf.isEmpty ? '0' : _numBuf;
          _numBuf = '$prefix.';
        }
      } else if (_numBuf.length < 5) {
        _numBuf = _numBuf == '0' ? k : '$_numBuf$k';
      }
    });
  }

  /// `:443-449` 范围校验：体重 20–300 / 体温 30–45，失败只提示不写。
  void _submitNumber(int low, int high, String title) {
    final parsed = double.tryParse(_numBuf);
    // Web `Number(buf||0)`：无小数点时是整数（避免 52 → 52.0）。
    final num value = _numBuf.contains('.')
        ? (parsed ?? double.nan)
        : (parsed?.toInt() ?? double.nan);
    if (_numBuf.isEmpty ||
        parsed == null ||
        parsed.isNaN ||
        parsed.isInfinite ||
        value < low ||
        value > high) {
      final msg = '$title需在 $low–$high 之间';
      setState(() => _inlineError = msg);
      ref
          .read(chatToastProvider.notifier)
          .show(msg, tone: ChatToastTone.warning);
      return;
    }
    _save(<String, dynamic>{widget.field: value});
  }

  // ── 爱爱（periodSexSheet :343-394） ─────────────────────────────────
  Widget _sexSheet(ThemeData theme, ColorScheme cs) {
    final e = _sexEntries[_sexCur];
    return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // tabs：`第 N 次` + `＋`（最多 8 次）
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (var i = 0; i < _sexEntries.length; i++)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    label: Text('第 ${i + 1} 次'),
                    selected: i == _sexCur,
                    onSelected: (_) => _selectSexTab(i),
                  ),
                ),
              ActionChip(
                label: const Text('＋'),
                onPressed: _saving ? null : _addSexEntry,
              ),
            ]),
          ),
          const SizedBox(height: 10),
          Text('爱爱', style: theme.textTheme.labelLarge),
          const SizedBox(height: 6),
          _optionGrid(
            <_Option>[
              for (var i = 0; i < periodSex.length; i++)
                _Option(i + 1, periodSex[i][0], periodSex[i][1]),
            ],
            null,
            theme,
            cs,
            multi: true,
            selected: (o) => e.w.contains(o.value),
            onTap: (o) {
              setState(() {
                if (e.w.contains(o.value)) {
                  e.w.remove(o.value);
                } else {
                  e.w.add(o.value);
                }
              });
              return Future<void>.value();
            },
          ),
          const SizedBox(height: 10),
          Text('时间', style: theme.textTheme.labelLarge),
          const SizedBox(height: 6),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            _timeWheel(_hours, _hourCtrl, true, theme),
            const Text(':', style: TextStyle(fontSize: 22)),
            _timeWheel(_minutes, _minuteCtrl, false, theme),
          ]),
          const SizedBox(height: 12),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            TextButton(
                onPressed: _saving ? null : () => Navigator.of(context).pop(),
                child: const Text('取消')),
            if (_sexEntries.length > 1) ...[
              const SizedBox(width: 6),
              TextButton(
                onPressed: _saving ? null : _deleteSexEntry,
                child: Text('删除这次',
                    style: TextStyle(color: cs.error)),
              ),
            ],
            const SizedBox(width: 6),
            FilledButton(
              onPressed: _saving
                  ? null
                  : () => _save(<String, dynamic>{
                        'sex': _sexEntries
                            .where((x) => x.w.isNotEmpty)
                            .map((x) => x.toJson())
                            .toList(),
                      }),
              child: const Text('确定'),
            ),
          ]),
        ]);
  }

  Widget _timeWheel(List<String> values, FixedExtentScrollController ctrl,
      bool isHour, ThemeData theme) {
    const itemExtent = 36.0;
    return SizedBox(
      width: 64,
      height: 120,
      child: ListWheelScrollView.useDelegate(
        controller: ctrl,
        itemExtent: itemExtent,
        physics: const FixedExtentScrollPhysics(),
        onSelectedItemChanged: (i) {
          if (_syncingWheel) return;
          final cur = _sexEntries[_sexCur];
          final (h, m) = _parseTime(cur.t);
          cur.t = '${_pad2(isHour ? i : h)}:${_pad2(isHour ? m : i)}';
        },
        childDelegate: ListWheelChildBuilderDelegate(
          childCount: values.length,
          builder: (ctx, i) => Center(
            child: Text(values[i], style: theme.textTheme.titleMedium),
          ),
        ),
      ),
    );
  }

  void _selectSexTab(int i) {
    if (i == _sexCur) return;
    final (h, m) = _parseTime(_sexEntries[i].t);
    _syncingWheel = true;
    setState(() => _sexCur = i);
    if (_hourCtrl.hasClients) _hourCtrl.jumpToItem(h);
    if (_minuteCtrl.hasClients) _minuteCtrl.jumpToItem(m);
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _syncingWheel = false);
  }

  void _addSexEntry() {
    if (_sexEntries.length >= 8) {
      ref.read(chatToastProvider.notifier).show('最多记八次');
      return;
    }
    _sexEntries.add(_SexDraft(widget.nowTime, <int>{}));
    _selectSexTab(_sexEntries.length - 1);
  }

  void _deleteSexEntry() {
    setState(() {
      _sexEntries.removeAt(_sexCur);
      if (_sexEntries.isEmpty) {
        _sexEntries.add(_SexDraft(widget.nowTime, <int>{}));
      }
      if (_sexCur >= _sexEntries.length) _sexCur = _sexEntries.length - 1;
    });
  }

  // ── 日记（periodLogSheet :453-460） ──────────────────────────────────
  Widget _contentSheet(ThemeData theme, ColorScheme cs) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _contentCtrl,
            maxLines: 5,
            maxLength: 20000,
            decoration: const InputDecoration(
              labelText: '想说的话',
              hintText: '今天特别难受，或者想让他知道的…',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 6),
          Text('日记只存在这一天里，历史卡上不会重复显示。',
              style: theme.textTheme.bodySmall?.copyWith(color: cs.outline)),
          const SizedBox(height: 10),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            TextButton(
                onPressed: _saving ? null : () => Navigator.of(context).pop(),
                child: const Text('取消')),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _saving
                  ? null
                  : () => _save(<String, dynamic>{
                        'content': _contentCtrl.text,
                      }),
              child: const Text('确定'),
            ),
          ]),
        ],
      );
}
