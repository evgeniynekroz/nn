import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:math_expressions/math_expressions.dart';
import 'package:local_auth/local_auth.dart';
import 'package:uuid/uuid.dart';
import 'package:intl/intl.dart';
import 'package:intl/date_symbol_data_local.dart';

// ─── PALETTE ─────────────────────────────────────────────────
const _purple  = Color(0xFF977DFF);
const _purple2 = Color(0xFF5B3FD4);
const _bgDark  = Color(0xFF0D0012);

// ─── MODELS ──────────────────────────────────────────────────

class NoteVersion {
  final String content;
  final DateTime savedAt;
  NoteVersion({required this.content, required this.savedAt});
  Map<String, dynamic> toJson() => {'content': content, 'savedAt': savedAt.toIso8601String()};
  factory NoteVersion.fromJson(Map<String, dynamic> j) =>
    NoteVersion(content: j['content'], savedAt: DateTime.parse(j['savedAt']));
}

class Note {
  String id, title, content, folder;
  DateTime createdAt, updatedAt;
  bool isPinned;
  Note({
    required this.id, this.title = '', this.content = '', this.folder = 'Все',
    required this.createdAt, required this.updatedAt, this.isPinned = false,
  });
  Map<String, dynamic> toJson() => {
    'id': id, 'title': title, 'content': content, 'folder': folder,
    'createdAt': createdAt.toIso8601String(), 'updatedAt': updatedAt.toIso8601String(),
    'isPinned': isPinned,
  };
  factory Note.fromJson(Map<String, dynamic> j) => Note(
    id: j['id'], title: j['title'] ?? '', content: j['content'] ?? '',
    folder: j['folder'] ?? 'Все',
    createdAt: DateTime.parse(j['createdAt']),
    updatedAt: DateTime.parse(j['updatedAt']),
    isPinned: j['isPinned'] ?? false,
  );
  Note copyWith({String? title, String? content, String? folder, bool? isPinned, DateTime? updatedAt}) => Note(
    id: id, title: title ?? this.title, content: content ?? this.content,
    folder: folder ?? this.folder, createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt, isPinned: isPinned ?? this.isPinned,
  );
}

// ─── STORE ───────────────────────────────────────────────────

class AppStore extends ChangeNotifier {
  final List<Note> _notes = [];
  final List<String> _folders = ['Все'];
  late Box _box, _cfg;
  ThemeMode _themeMode = ThemeMode.system;
  bool _hasPin = false;
  String _pin = '';
  bool _onboardingDone = false;

  List<Note> get notes => List.unmodifiable(_notes);
  List<String> get folders => List.unmodifiable(_folders);
  ThemeMode get themeMode => _themeMode;
  bool get hasPin => _hasPin;
  String get pin => _pin;
  bool get onboardingDone => _onboardingDone;

  Future<void> init() async {
    _box = await Hive.openBox('nnotes_v2');
    _cfg = await Hive.openBox('nnotes_cfg');
    _notes.addAll(
      (jsonDecode(_box.get('notes', defaultValue: '[]')) as List).map((e) => Note.fromJson(e)));
    _folders..clear()..addAll(
      (jsonDecode(_box.get('folders', defaultValue: '["Все"]')) as List).cast<String>());
    final tm = _cfg.get('theme', defaultValue: 'system') as String;
    _themeMode = tm == 'light' ? ThemeMode.light : tm == 'dark' ? ThemeMode.dark : ThemeMode.system;
    _hasPin = _cfg.get('hasPin', defaultValue: false) as bool;
    _pin = _cfg.get('pin', defaultValue: '') as String;
    _onboardingDone = _cfg.get('onboardingDone', defaultValue: false) as bool;
    notifyListeners();
  }

  void _persist() {
    _box.put('notes', jsonEncode(_notes.map((n) => n.toJson()).toList()));
    _box.put('folders', jsonEncode(_folders));
  }

  void addNote(Note n)    { _notes.insert(0, n); _persist(); notifyListeners(); }
  void deleteNote(String id) {
    _notes.removeWhere((n) => n.id == id);
    _box.delete('hist_$id');
    _persist(); notifyListeners();
  }
  void updateNote(Note n) {
    final i = _notes.indexWhere((e) => e.id == n.id);
    if (i != -1) { _notes[i] = n; _persist(); notifyListeners(); }
  }
  void addFolder(String f) {
    if (!_folders.contains(f)) { _folders.add(f); _persist(); notifyListeners(); }
  }
  void removeFolder(String f) {
    if (f == 'Все') return;
    _folders.remove(f);
    for (final n in _notes) { if (n.folder == f) n.folder = 'Все'; }
    _persist(); notifyListeners();
  }

  List<Note> byFolder(String f) => f == 'Все' ? _notes : _notes.where((n) => n.folder == f).toList();
  List<Note> search(String q) {
    final lq = q.toLowerCase();
    return _notes.where((n) =>
      n.title.toLowerCase().contains(lq) || n.content.toLowerCase().contains(lq)).toList();
  }

  List<NoteVersion> getHistory(String id) =>
    (jsonDecode(_box.get('hist_$id', defaultValue: '[]')) as List)
      .map((e) => NoteVersion.fromJson(e)).toList();

  void saveVersion(String id, String content) {
    final h = getHistory(id)..insert(0, NoteVersion(content: content, savedAt: DateTime.now()));
    if (h.length > 5) h.removeLast();
    _box.put('hist_$id', jsonEncode(h.map((v) => v.toJson()).toList()));
  }

  void setTheme(ThemeMode m) {
    _themeMode = m;
    _cfg.put('theme', m == ThemeMode.light ? 'light' : m == ThemeMode.dark ? 'dark' : 'system');
    notifyListeners();
  }
  void setPin(String p) {
    _pin = p; _hasPin = p.isNotEmpty;
    _cfg.put('pin', p); _cfg.put('hasPin', p.isNotEmpty);
    notifyListeners();
  }
  void completeOnboarding() {
    _onboardingDone = true; _cfg.put('onboardingDone', true); notifyListeners();
  }
}

// ─── MATH ────────────────────────────────────────────────────

class MathHelper {
  static final _rx = RegExp(
    r'(\d[\d\s]*[\+\-\*\/\^]\s*[\d\s]+(?:\s*=\s*\??)?|\d+\s*[\+\-\*\/]\s*\d+)',
    caseSensitive: false);
  static String? detect(String t) => _rx.firstMatch(t)?.group(0);
  static String? solve(String expr) {
    try {
      final c = expr.replaceAll('', '^2').replaceAll('?', '').replaceAll(RegExp(r'=.*'), '').trim();
      if (c.isEmpty) return null;
      final r = Parser().parse(c).evaluate(EvaluationType.REAL, ContextModel());
      return r.toStringAsFixed(r % 1 == 0 ? 0 : 4);
    } catch (_) { return null; }
  }
}

// ─── ENTRY ───────────────────────────────────────────────────

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();
  await initializeDateFormatting('ru', null);
  final store = AppStore();
  await store.init();
  runApp(NNotesApp(store: store));
}

// ─── APP ─────────────────────────────────────────────────────

class NNotesApp extends StatelessWidget {
  final AppStore store;
  const NNotesApp({super.key, required this.store});

  ThemeData _theme(Brightness br) {
    final dark = br == Brightness.dark;
    return ThemeData(
      useMaterial3: true, brightness: br,
      colorScheme: dark
        ? const ColorScheme.dark(
            primary: _purple, onPrimary: Colors.white,
            secondary: Color(0xFFBBA4FF), surface: _bgDark, onSurface: Colors.white,
            surfaceContainerLowest: Color(0xFF100018),
            surfaceContainerLow: Color(0xFF1A0030),
            surfaceContainer: Color(0xFF220040),
            surfaceContainerHigh: Color(0xFF2D1A55),
            surfaceContainerHighest: Color(0xFF3A2268),
            outline: Color(0xFF6A5099), outlineVariant: Color(0xFF3A2268))
        : const ColorScheme.light(
            primary: _purple, onPrimary: Colors.white,
            secondary: _purple2, surface: Colors.white, onSurface: Colors.black,
            surfaceContainerLowest: Color(0xFFF8F5FF),
            surfaceContainerLow: Color(0xFFF0ECFF),
            surfaceContainer: Color(0xFFE8E0FF),
            surfaceContainerHigh: Color(0xFFDDD5FF),
            surfaceContainerHighest: Color(0xFFD0C4FF),
            outline: Color(0xFF9988CC), outlineVariant: Color(0xFFE0D8FF)),
      textTheme: GoogleFonts.interTextTheme(ThemeData(brightness: br).textTheme),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (_, __) => MaterialApp(
      title: 'NNotes',
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: store.themeMode,
      home: store.onboardingDone ? MainShell(store: store) : OnboardingScreen(store: store),
    ),
  );
}

// ─── ONBOARDING ──────────────────────────────────────────────

class OnboardingScreen extends StatefulWidget {
  final AppStore store;
  const OnboardingScreen({super.key, required this.store});
  @override State<OnboardingScreen> createState() => _OnboardingState();
}

class _OnboardingState extends State<OnboardingScreen> {
  final _ctrl = PageController();
  int _page = 0;

  static const _pages = [
    (Icons.note_alt_rounded, 'Добро пожаловать\nв NNotes', 'Умные заметки с Markdown,\nрисованием и математикой'),
    (Icons.draw_rounded, 'Пиши как хочешь', 'Markdown, таблицы, формулы,\nрисование — всё в одном'),
    (Icons.folder_special_rounded, 'Всё под рукой', 'Папки, поиск, темы оформления\nи пин-код по желанию'),
  ];

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      body: Stack(children: [
        Positioned.fill(child: _GradientBg(isDark: isDark)),
        SafeArea(child: Column(children: [
          Align(alignment: Alignment.topRight, child: Padding(
            padding: const EdgeInsets.all(8),
            child: TextButton(
              onPressed: widget.store.completeOnboarding,
              child: Text('Пропустить', style: TextStyle(color: cs.primary)),
            ),
          )),
          Expanded(child: PageView.builder(
            controller: _ctrl,
            itemCount: _pages.length,
            onPageChanged: (i) => setState(() => _page = i),
            itemBuilder: (_, i) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 36),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Container(
                  width: 120, height: 120,
                  decoration: BoxDecoration(
                    color: cs.primary.withOpacity(.12),
                    borderRadius: BorderRadius.circular(36)),
                  child: Icon(_pages[i].$1, size: 60, color: cs.primary),
                ),
                const SizedBox(height: 40),
                Text(_pages[i].$2, textAlign: TextAlign.center,
                  style: GoogleFonts.inter(fontSize: 30, fontWeight: FontWeight.w800, height: 1.2)),
                const SizedBox(height: 16),
                Text(_pages[i].$3, textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 17, color: cs.onSurface.withOpacity(.6), height: 1.55)),
              ]),
            ),
          )),
          Row(mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(_pages.length, (i) => AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              margin: const EdgeInsets.all(4),
              width: i == _page ? 24 : 8, height: 8,
              decoration: BoxDecoration(
                color: i == _page ? cs.primary : cs.outline.withOpacity(.35),
                borderRadius: BorderRadius.circular(4)),
            ))),
          const SizedBox(height: 32),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 28),
            child: SizedBox(width: double.infinity, height: 56,
              child: FilledButton(
                onPressed: () {
                  if (_page < _pages.length - 1) {
                    _ctrl.nextPage(duration: const Duration(milliseconds: 400), curve: Curves.easeOutCubic);
                  } else {
                    widget.store.completeOnboarding();
                  }
                },
                style: FilledButton.styleFrom(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18))),
                child: Text(_page < _pages.length - 1 ? 'Далее' : 'Начать',
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
              ),
            ),
          ),
          const SizedBox(height: 40),
        ])),
      ]),
    );
  }
}

// ─── MAIN SHELL ──────────────────────────────────────────────

class MainShell extends StatefulWidget {
  final AppStore store;
  const MainShell({super.key, required this.store});
  @override State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _tab = 0;
  bool _unlocked = false;

  @override
  void initState() {
    super.initState();
    widget.store.hasPin ? _unlock() : setState(() => _unlocked = true);
  }

  Future<void> _unlock() async {
    try {
      final auth = LocalAuthentication();
      if (await auth.canCheckBiometrics) {
        final ok = await auth.authenticate(
          localizedReason: 'Войди в NNotes',
          options: const AuthenticationOptions(biometricOnly: true));
        if (ok && mounted) { setState(() => _unlocked = true); return; }
      }
    } catch (_) {}
    if (!mounted) return;
    final ok = await Navigator.push<bool>(context, MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => PinScreen(store: widget.store, mode: PinMode.check)));
    if (ok == true && mounted) setState(() => _unlocked = true);
  }

  @override
  Widget build(BuildContext context) {
    if (!_unlocked) return const Scaffold(
      body: Center(child: CircularProgressIndicator(color: _purple)));
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final tabs = [
      NotesTab(store: widget.store),
      SearchTab(store: widget.store),
      FoldersTab(store: widget.store),
      SettingsTab(store: widget.store),
    ];
    return Scaffold(
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 280),
        transitionBuilder: (child, anim) => FadeTransition(
          opacity: anim,
          child: SlideTransition(
            position: Tween(begin: const Offset(0, 0.03), end: Offset.zero)
              .animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
            child: child,
          ),
        ),
        child: KeyedSubtree(key: ValueKey(_tab), child: tabs[_tab]),
      ),
      bottomNavigationBar: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: (i) => setState(() => _tab = i),
            elevation: 0,
            backgroundColor: isDark ? Colors.white.withOpacity(.05) : Colors.white.withOpacity(.75),
            destinations: const [
              NavigationDestination(icon: Icon(Icons.note_alt_outlined), selectedIcon: Icon(Icons.note_alt), label: 'Заметки'),
              NavigationDestination(icon: Icon(Icons.search_outlined), selectedIcon: Icon(Icons.search), label: 'Поиск'),
              NavigationDestination(icon: Icon(Icons.folder_outlined), selectedIcon: Icon(Icons.folder), label: 'Папки'),
              NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: 'Настройки'),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── NOTES TAB ───────────────────────────────────────────────

class NotesTab extends StatefulWidget {
  final AppStore store;
  const NotesTab({super.key, required this.store});
  @override State<NotesTab> createState() => _NotesTabState();
}

class _NotesTabState extends State<NotesTab> {
  String _folder = 'Все';

  List<Note> get _visible {
    final b = widget.store.byFolder(_folder);
    return [...b.where((n) => n.isPinned), ...b.where((n) => !n.isPinned)];
  }

  void _open([Note? note]) async {
    await Navigator.push(context, _slideRoute(NoteEditor(store: widget.store, note: note)));
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Stack(children: [
      Positioned.fill(child: _GradientBg(isDark: isDark)),
      SafeArea(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.fromLTRB(22, 20, 22, 0),
          child: Text('NNotes',
            style: GoogleFonts.inter(fontSize: 36, fontWeight: FontWeight.w800))),
        if (widget.store.folders.length > 1) ...[
          const SizedBox(height: 14),
          SizedBox(height: 36, child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            itemCount: widget.store.folders.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (_, i) {
              final f = widget.store.folders[i];
              return FilterChip(
                label: Text(f), selected: f == _folder,
                onSelected: (_) => setState(() => _folder = f),
                showCheckmark: false);
            },
          )),
        ],
        const SizedBox(height: 12),
        Expanded(child: _visible.isEmpty
          ? _Empty()
          : _DepthList(
              notes: _visible,
              onTap: (n) => _open(n),
              onDelete: (n) { widget.store.deleteNote(n.id); setState(() {}); },
              onPin: (n) { widget.store.updateNote(n.copyWith(isPinned: !n.isPinned)); setState(() {}); },
            )),
      ])),
      Positioned(bottom: 16, right: 20,
        child: FloatingActionButton.extended(
          onPressed: () => _open(),
          icon: const Icon(Icons.add),
          label: const Text('Заметка'),
          backgroundColor: cs.primary, foregroundColor: Colors.white,
        )),
    ]);
  }
}

// ─── DEPTH LIST ──────────────────────────────────────────────

class _DepthList extends StatefulWidget {
  final List<Note> notes;
  final void Function(Note) onTap, onDelete, onPin;
  const _DepthList({required this.notes, required this.onTap, required this.onDelete, required this.onPin});
  @override State<_DepthList> createState() => _DepthListState();
}

class _DepthListState extends State<_DepthList> {
  final _ctrl = ScrollController();
  double _scroll = 0;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(() { if (mounted) setState(() => _scroll = _ctrl.offset); });
  }
  @override void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    const itemH = 96.0, gap = 12.0;
    final viewCenter = MediaQuery.of(context).size.height * 0.42;
    return ListView.builder(
      controller: _ctrl,
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 100),
      itemCount: widget.notes.length,
      itemBuilder: (_, i) {
        final center = i * (itemH + gap) + itemH / 2 - _scroll;
        final dist = (center - viewCenter).abs();
        final t = (dist / (viewCenter * 0.95)).clamp(0.0, 1.0);
        final scale = 1.0 - t * 0.055;
        final opacity = (1.0 - t * 0.2).clamp(0.35, 1.0);
        return Padding(
          padding: const EdgeInsets.only(bottom: gap),
          child: Transform.scale(scale: scale,
            child: Opacity(opacity: opacity,
              child: _NoteCard(
                note: widget.notes[i],
                onTap: () => widget.onTap(widget.notes[i]),
                onDelete: () => widget.onDelete(widget.notes[i]),
                onPin: () => widget.onPin(widget.notes[i]),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ─── NOTE CARD (LIQUID GLASS) ────────────────────────────────

class _NoteCard extends StatelessWidget {
  final Note note;
  final VoidCallback onTap, onDelete, onPin;
  const _NoteCard({required this.note, required this.onTap, required this.onDelete, required this.onPin});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: onTap,
      onLongPress: () => showModalBottomSheet(
        context: context, useRootNavigator: true, backgroundColor: Colors.transparent,
        builder: (_) => _Sheet(children: [
          ListTile(
            leading: Icon(note.isPinned ? Icons.push_pin_outlined : Icons.push_pin, color: _purple),
            title: Text(note.isPinned ? 'Открепить' : 'Закрепить'),
            onTap: () { Navigator.pop(context); onPin(); },
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
            title: const Text('Удалить', style: TextStyle(color: Colors.redAccent)),
            onTap: () { Navigator.pop(context); onDelete(); },
          ),
        ]),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: Container(
            height: 96,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              color: isDark ? Colors.white.withOpacity(.07) : Colors.white.withOpacity(.75),
              border: Border.all(color: _purple.withOpacity(isDark ? .2 : .12), width: 1),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            child: Row(children: [
              if (note.isPinned) ...[
                const Icon(Icons.push_pin, size: 13, color: _purple),
                const SizedBox(width: 6),
              ],
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (note.title.isNotEmpty) ...[
                    Text(note.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(fontWeight: FontWeight.w700, fontSize: 15, color: cs.onSurface)),
                    const SizedBox(height: 5),
                  ],
                  Text(note.content.replaceAll('\n', ' '),
                    maxLines: note.title.isEmpty ? 2 : 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: cs.onSurface.withOpacity(.52), height: 1.4)),
                ],
              )),
              const SizedBox(width: 10),
              Text(_fmt(note.updatedAt), style: TextStyle(fontSize: 11, color: cs.outline)),
            ]),
          ),
        ),
      ),
    );
  }

  String _fmt(DateTime dt) {
    final d = DateTime.now().difference(dt).inDays;
    if (d == 0) return 'Сегодня';
    if (d == 1) return 'Вчера';
    return DateFormat('d MMM', 'ru').format(dt);
  }
}

// ─── SEARCH TAB ──────────────────────────────────────────────

class SearchTab extends StatefulWidget {
  final AppStore store;
  const SearchTab({super.key, required this.store});
  @override State<SearchTab> createState() => _SearchTabState();
}

class _SearchTabState extends State<SearchTab> {
  final _ctrl = TextEditingController();
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final results = _q.isEmpty ? <Note>[] : widget.store.search(_q);
    return Stack(children: [
      Positioned.fill(child: _GradientBg(isDark: isDark)),
      SafeArea(child: Column(children: [
        Padding(padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          child: ClipRRect(borderRadius: BorderRadius.circular(16),
            child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
              child: SearchBar(
                controller: _ctrl,
                hintText: 'Поиск по заметкам...',
                leading: const Padding(padding: EdgeInsets.only(left: 4), child: Icon(Icons.search)),
                trailing: [if (_q.isNotEmpty) IconButton(icon: const Icon(Icons.close),
                  onPressed: () => setState(() { _q = ''; _ctrl.clear(); }))],
                onChanged: (v) => setState(() => _q = v),
                elevation: const WidgetStatePropertyAll(0),
                backgroundColor: WidgetStatePropertyAll(
                  isDark ? Colors.white.withOpacity(.07) : Colors.white.withOpacity(.72)),
              ),
            ),
          ),
        ),
        Expanded(child: _q.isEmpty
          ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.search, size: 64, color: cs.outline.withOpacity(.35)),
              const SizedBox(height: 12),
              Text('Начни вводить запрос', style: TextStyle(color: cs.outline)),
            ]))
          : results.isEmpty
            ? Center(child: Text('Ничего не найдено', style: TextStyle(color: cs.outline)))
            : _DepthList(
                notes: results,
                onTap: (n) async {
                  await Navigator.push(context, _slideRoute(NoteEditor(store: widget.store, note: n)));
                  setState(() {});
                },
                onDelete: (n) { widget.store.deleteNote(n.id); setState(() {}); },
                onPin: (n) { widget.store.updateNote(n.copyWith(isPinned: !n.isPinned)); setState(() {}); },
              )),
      ])),
    ]);
  }
}

// ─── FOLDERS TAB ─────────────────────────────────────────────

class FoldersTab extends StatefulWidget {
  final AppStore store;
  const FoldersTab({super.key, required this.store});
  @override State<FoldersTab> createState() => _FoldersTabState();
}

class _FoldersTabState extends State<FoldersTab> {
  void _add() {
    final c = TextEditingController();
    showDialog(context: context, builder: (_) => AlertDialog(
      title: const Text('Новая папка'),
      content: TextField(controller: c, autofocus: true,
        decoration: const InputDecoration(hintText: 'Название папки')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
        FilledButton(onPressed: () {
          if (c.text.trim().isNotEmpty) widget.store.addFolder(c.text.trim());
          Navigator.pop(context); setState(() {});
        }, child: const Text('Создать')),
      ],
    ));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Stack(children: [
      Positioned.fill(child: _GradientBg(isDark: isDark)),
      SafeArea(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.fromLTRB(22, 20, 22, 16),
          child: Row(children: [
            Text('Папки', style: GoogleFonts.inter(fontSize: 28, fontWeight: FontWeight.w800)),
            const Spacer(),
            FilledButton.icon(onPressed: _add,
              icon: const Icon(Icons.add, size: 18), label: const Text('Новая'),
              style: FilledButton.styleFrom(visualDensity: VisualDensity.compact)),
          ])),
        Expanded(child: ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
          itemCount: widget.store.folders.length,
          itemBuilder: (_, i) {
            final f = widget.store.folders[i];
            final count = widget.store.byFolder(f).length;
            return Padding(padding: const EdgeInsets.only(bottom: 10),
              child: ClipRRect(borderRadius: BorderRadius.circular(18),
                child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(18),
                      color: isDark ? Colors.white.withOpacity(.07) : Colors.white.withOpacity(.72),
                      border: Border.all(color: _purple.withOpacity(.14))),
                    child: ListTile(
                      leading: Icon(f == 'Все' ? Icons.all_inbox_rounded : Icons.folder_rounded, color: cs.primary),
                      title: Text(f, style: const TextStyle(fontWeight: FontWeight.w600)),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(color: cs.primary.withOpacity(.12), borderRadius: BorderRadius.circular(10)),
                          child: Text('$count', style: TextStyle(color: cs.primary, fontWeight: FontWeight.w700, fontSize: 13))),
                        if (f != 'Все') IconButton(
                          icon: const Icon(Icons.delete_outline, size: 20, color: Colors.redAccent),
                          onPressed: () { widget.store.removeFolder(f); setState(() {}); }),
                      ]),
                    ),
                  ),
                ),
              ),
            );
          },
        )),
      ])),
    ]);
  }
}

// ─── SETTINGS TAB ────────────────────────────────────────────

class SettingsTab extends StatefulWidget {
  final AppStore store;
  const SettingsTab({super.key, required this.store});
  @override State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> {
  void _managePin() async {
    if (widget.store.hasPin) {
      final ok = await Navigator.push<bool>(context, MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => PinScreen(store: widget.store, mode: PinMode.check)));
      if (ok == true) { widget.store.setPin(''); setState(() {}); }
    } else {
      await Navigator.push(context, MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => PinScreen(store: widget.store, mode: PinMode.create)));
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Stack(children: [
      Positioned.fill(child: _GradientBg(isDark: isDark)),
      SafeArea(child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 100),
        children: [
          Padding(padding: const EdgeInsets.only(left: 4, bottom: 20),
            child: Text('Настройки', style: GoogleFonts.inter(fontSize: 28, fontWeight: FontWeight.w800))),

          _Section(isDark: isDark, label: 'ТЕМА', child: Column(
            children: [
              for (final opt in [
                (ThemeMode.system, Icons.brightness_auto, 'Системная'),
                (ThemeMode.light, Icons.light_mode, 'Светлая'),
                (ThemeMode.dark, Icons.dark_mode, 'Тёмная'),
              ]) ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(opt.$2,
                  color: widget.store.themeMode == opt.$1 ? _purple : Theme.of(context).colorScheme.outline),
                title: Text(opt.$3, style: TextStyle(
                  fontWeight: widget.store.themeMode == opt.$1 ? FontWeight.w600 : FontWeight.normal,
                  color: widget.store.themeMode == opt.$1 ? _purple : null)),
                trailing: widget.store.themeMode == opt.$1
                  ? const Icon(Icons.check_circle_rounded, color: _purple) : null,
                onTap: () { widget.store.setTheme(opt.$1); setState(() {}); },
              ),
            ],
          )),
          const SizedBox(height: 12),

          _Section(isDark: isDark, label: 'БЕЗОПАСНОСТЬ', child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(widget.store.hasPin ? Icons.lock_rounded : Icons.lock_open_outlined, color: _purple),
            title: Text(widget.store.hasPin ? 'Пин-код установлен' : 'Пин-код'),
            subtitle: Text(widget.store.hasPin ? 'Нажми чтобы удалить' : 'Защити заметки пин-кодом'),
            trailing: Switch(value: widget.store.hasPin, onChanged: (_) => _managePin()),
          )),
          const SizedBox(height: 12),

          _Section(isDark: isDark, label: 'О ПРИЛОЖЕНИИ', child: Column(children: [
            const ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.note_alt_rounded, color: _purple),
              title: Text('NNotes', style: TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text('Версия 1.0.0 • Open Source'),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.help_outline, color: _purple),
              title: const Text('Смотреть обучение снова'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(context, _slideRoute(OnboardingScreen(store: widget.store))),
            ),
          ])),
        ],
      )),
    ]);
  }
}

class _Section extends StatelessWidget {
  final String label;
  final Widget child;
  final bool isDark;
  const _Section({required this.label, required this.child, required this.isDark});
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(padding: const EdgeInsets.only(left: 6, bottom: 8),
        child: Text(label, style: const TextStyle(
          fontSize: 11, fontWeight: FontWeight.w700, color: _purple, letterSpacing: 1))),
      ClipRRect(borderRadius: BorderRadius.circular(18),
        child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              color: isDark ? Colors.white.withOpacity(.07) : Colors.white.withOpacity(.72),
              border: Border.all(color: _purple.withOpacity(.13))),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: child,
          ),
        ),
      ),
    ],
  );
}

// ─── PIN SCREEN ──────────────────────────────────────────────

enum PinMode { create, check }

class PinScreen extends StatefulWidget {
  final AppStore store;
  final PinMode mode;
  const PinScreen({super.key, required this.store, required this.mode});
  @override State<PinScreen> createState() => _PinScreenState();
}

class _PinScreenState extends State<PinScreen> with SingleTickerProviderStateMixin {
  String _input = '', _temp = '';
  bool _confirming = false;
  late AnimationController _shake;

  @override
  void initState() {
    super.initState();
    _shake = AnimationController(vsync: this, duration: const Duration(milliseconds: 400));
  }
  @override void dispose() { _shake.dispose(); super.dispose(); }

  String get _prompt => widget.mode == PinMode.check ? 'Введи пин-код'
    : _confirming ? 'Повтори пин-код' : 'Создай пин-код';

  void _tap(String k) {
    if (_input.length >= 4) return;
    final next = _input + k;
    setState(() => _input = next);
    if (next.length < 4) return;
    if (widget.mode == PinMode.check) {
      if (next == widget.store.pin) { Navigator.pop(context, true); return; }
      HapticFeedback.vibrate(); _shake.forward(from: 0);
      setState(() => _input = ''); return;
    }
    if (!_confirming) { setState(() { _temp = next; _input = ''; _confirming = true; }); return; }
    if (next == _temp) { widget.store.setPin(next); Navigator.pop(context, true); return; }
    HapticFeedback.vibrate(); _shake.forward(from: 0);
    setState(() { _input = ''; _confirming = false; _temp = ''; });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(gradient: LinearGradient(
          begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: isDark ? [_bgDark, const Color(0xFF1A0033)] : [const Color(0xFFF0ECFF), Colors.white],
        )),
        child: SafeArea(child: Column(children: [
          if (widget.mode == PinMode.create)
            Align(alignment: Alignment.topRight, child: Padding(
              padding: const EdgeInsets.all(8),
              child: TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
            )),
          const Spacer(),
          Container(width: 72, height: 72,
            decoration: BoxDecoration(color: _purple.withOpacity(.12), borderRadius: BorderRadius.circular(22)),
            child: const Icon(Icons.lock_rounded, size: 36, color: _purple)),
          const SizedBox(height: 28),
          Text(_prompt, style: GoogleFonts.inter(fontSize: 22, fontWeight: FontWeight.w700)),
          const SizedBox(height: 32),
          AnimatedBuilder(
            animation: _shake,
            builder: (_, child) => Transform.translate(
              offset: Offset((_shake.value < 0.5 ? _shake.value * 24 - 6 : (1 - _shake.value) * -24 + 6), 0),
              child: child),
            child: Row(mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(4, (i) => AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                margin: const EdgeInsets.all(10), width: 14, height: 14,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: i < _input.length ? _purple : _purple.withOpacity(.22)),
              ))),
          ),
          const SizedBox(height: 40),
          for (final row in [['1','2','3'],['4','5','6'],['7','8','9']])
            Row(mainAxisAlignment: MainAxisAlignment.center,
              children: row.map((n) => _Key(n, () => _tap(n))).toList()),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            const SizedBox(width: 90),
            _Key('0', () => _tap('0')),
            _Key('⌫', () { if (_input.isNotEmpty) setState(() => _input = _input.substring(0, _input.length - 1)); }),
          ]),
          const Spacer(),
        ])),
      ),
    );
  }
}

class _Key extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _Key(this.label, this.onTap);
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 82, height: 82, margin: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: isDark ? Colors.white.withOpacity(.07) : _purple.withOpacity(.08),
          borderRadius: BorderRadius.circular(22)),
        alignment: Alignment.center,
        child: Text(label, style: GoogleFonts.inter(fontSize: 24, fontWeight: FontWeight.w600)),
      ),
    );
  }
}

// ─── NOTE EDITOR ─────────────────────────────────────────────

class NoteEditor extends StatefulWidget {
  final AppStore store;
  final Note? note;
  const NoteEditor({super.key, required this.store, this.note});
  @override State<NoteEditor> createState() => _NoteEditorState();
}

class _NoteEditorState extends State<NoteEditor> {
  late TextEditingController _title, _content;
  bool _preview = false, _drawing = false;
  String _folder = 'Все';
  bool _pinned = false;
  String? _mathExpr;

  final List<_Pt> _pts = [];
  Color _penColor = _purple;
  double _penW = 4;
  bool _eraser = false;

  @override
  void initState() {
    super.initState();
    final n = widget.note;
    _title   = TextEditingController(text: n?.title ?? '');
    _content = TextEditingController(text: n?.content ?? '');
    if (n != null) { _folder = n.folder; _pinned = n.isPinned; }
    _content.addListener(() {
      final e = MathHelper.detect(_content.text);
      if (e != _mathExpr) setState(() => _mathExpr = e);
    });
  }
  @override void dispose() { _title.dispose(); _content.dispose(); super.dispose(); }

  void _save() {
    final now = DateTime.now();
    final n = widget.note;
    final id = n?.id ?? const Uuid().v4();
    if (n != null && n.content != _content.text) widget.store.saveVersion(id, n.content);
    final note = Note(id: id, title: _title.text.trim(), content: _content.text,
      folder: _folder, createdAt: n?.createdAt ?? now, updatedAt: now, isPinned: _pinned);
    n == null ? widget.store.addNote(note) : widget.store.updateNote(note);
  }

  void _md(String b, [String a = '']) {
    final s = _content.selection, t = _content.text;
    final pos = s.isValid ? s.start : t.length;
    if (!s.isValid || s.isCollapsed) {
      _content.value = TextEditingValue(
        text: t.substring(0, pos) + b + a + t.substring(pos),
        selection: TextSelection.collapsed(offset: pos + b.length));
    } else {
      final sel = t.substring(s.start, s.end);
      final rep = '$b$sel$a';
      _content.value = TextEditingValue(
        text: t.replaceRange(s.start, s.end, rep),
        selection: TextSelection.collapsed(offset: s.start + rep.length));
    }
  }

  void _showHistory() {
    if (widget.note == null) return;
    final h = widget.store.getHistory(widget.note!.id);
    if (h.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('История пуста')));
      return;
    }
    showModalBottomSheet(
      context: context, backgroundColor: Colors.transparent, isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: .5, minChildSize: .3, maxChildSize: .85,
        builder: (_, __) => _Sheet(children: [
          const Padding(padding: EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Text('История версий', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
          ...h.map((v) => ListTile(
            title: Text(DateFormat('d MMM, HH:mm', 'ru').format(v.savedAt)),
            subtitle: Text(v.content, maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: FilledButton.tonal(
              onPressed: () { _content.text = v.content; Navigator.pop(context); },
              style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
              child: const Text('Откат')),
          )),
        ]),
      ),
    );
  }

  void _showMath() {
    if (_mathExpr == null) return;
    final res = MathHelper.solve(_mathExpr!);
    showModalBottomSheet(
      context: context, backgroundColor: Colors.transparent,
      builder: (_) => _Sheet(children: [
        Padding(padding: const EdgeInsets.fromLTRB(20, 4, 20, 20), child: Column(
          crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min,
          children: [
            Text('Выражение', style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.outline)),
            const SizedBox(height: 6),
            Text(_mathExpr!, style: GoogleFonts.jetBrainsMono(fontSize: 18)),
            const Divider(height: 28),
            Text('Результат', style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.outline)),
            const SizedBox(height: 6),
            Text(res != null ? '= $res' : 'Не удалось вычислить',
              style: GoogleFonts.inter(fontSize: 42, fontWeight: FontWeight.w800, color: _purple)),
          ],
        )),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) { if (!didPop) { _save(); Navigator.pop(context); } },
      child: Scaffold(
        body: Stack(children: [
          Positioned.fill(child: _GradientBg(isDark: isDark)),
          SafeArea(child: Column(children: [
            Padding(padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Row(children: [
                IconButton(icon: const Icon(Icons.arrow_back_ios_new_rounded),
                  onPressed: () { _save(); Navigator.pop(context); }),
                const Spacer(),
                IconButton(icon: Icon(_pinned ? Icons.push_pin : Icons.push_pin_outlined),
                  onPressed: () => setState(() => _pinned = !_pinned)),
                IconButton(icon: const Icon(Icons.folder_outlined),
                  onPressed: () => showModalBottomSheet(
                    context: context, backgroundColor: Colors.transparent,
                    builder: (_) => _Sheet(children: widget.store.folders.map((f) => ListTile(
                      leading: Icon(_folder == f ? Icons.folder : Icons.folder_outlined,
                        color: _folder == f ? _purple : null),
                      title: Text(f),
                      onTap: () { setState(() => _folder = f); Navigator.pop(context); },
                    )).toList()),
                  )),
                if (widget.note != null)
                  IconButton(icon: const Icon(Icons.history_rounded), onPressed: _showHistory),
                IconButton(
                  icon: Icon(_preview ? Icons.edit_note : Icons.visibility_outlined),
                  onPressed: () => setState(() { _preview = !_preview; _drawing = false; })),
                IconButton(
                  icon: Icon(_drawing ? Icons.text_fields : Icons.draw_outlined),
                  onPressed: () => setState(() { _drawing = !_drawing; _preview = false; })),
              ]),
            ),
            Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: TextField(
                controller: _title,
                style: GoogleFonts.inter(fontSize: 26, fontWeight: FontWeight.w800),
                decoration: InputDecoration(
                  hintText: 'Заголовок',
                  hintStyle: TextStyle(color: cs.outline.withOpacity(.4)),
                  border: InputBorder.none),
                maxLines: 2, minLines: 1,
              ),
            ),
            if (_mathExpr != null && !_drawing)
              Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: FilledButton.icon(
                  onPressed: _showMath,
                  icon: const Icon(Icons.functions_rounded, size: 16),
                  label: Text('Решить: $_mathExpr', overflow: TextOverflow.ellipsis),
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8)),
                )),
            if (!_preview && !_drawing) _MdBar(onMd: _md),
            if (_drawing) _DrawBar(
              color: _penColor, width: _penW, isEraser: _eraser,
              onColor: (c) => setState(() => _penColor = c),
              onWidth: (w) => setState(() => _penW = w),
              onEraser: () => setState(() => _eraser = !_eraser),
              onClear: () => setState(() => _pts.clear()),
            ),
            Expanded(child: _drawing
              ? _Canvas(pts: _pts, color: _penColor, width: _penW, eraser: _eraser,
                  onAdd: (p) => setState(() => _pts.add(p)))
              : _preview
                ? Markdown(
                    data: _content.text, selectable: true,
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                    onTapLink: (_, href, __) async {
                      final u = href != null ? Uri.tryParse(href) : null;
                      if (u != null && await canLaunchUrl(u)) launchUrl(u);
                    })
                : TextField(
                    controller: _content, maxLines: null, expands: true,
                    keyboardType: TextInputType.multiline,
                    style: const TextStyle(fontSize: 16, height: 1.7),
                    decoration: InputDecoration(
                      hintText: 'Начни писать...',
                      hintStyle: TextStyle(color: cs.outline.withOpacity(.4)),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.fromLTRB(20, 8, 20, 20)),
                    contextMenuBuilder: (ctx, state) => AdaptiveTextSelectionToolbar(
                      anchors: state.contextMenuAnchors,
                      children: [
                        ...AdaptiveTextSelectionToolbar.getAdaptiveButtons(ctx, state.contextMenuButtonItems),
                        ...[
                          ('Жирный', '**', '**'), ('Курсив', '*', '*'),
                          ('~~', '~~', '~~'), ('Код', '`', '`'),
                          ('Ссылка', '[', '](https://)'),
                        ].map((e) => TextSelectionToolbarTextButton(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          onPressed: () { _md(e.$2, e.$3); state.hideToolbar(); },
                          child: Text(e.$1))),
                      ]),
                  ),
            ),
          ])),
        ]),
      ),
    );
  }
}

// ─── MD TOOLBAR ──────────────────────────────────────────────

class _MdBar extends StatelessWidget {
  final void Function(String, [String]) onMd;
  const _MdBar({required this.onMd});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    const btns = [
      ('B','**','**'),('I','*','*'),('~~','~~','~~'),
      ('H1','# ',''),('H2','## ',''),('H3','### ',''),
      ('`','`','`'),('```','```\n','\n```'),
      ('🔗','[','](https://)'),('- ','\n- ',''),
      ('☑','\n- [ ] ',''),('> ','> ',''),
      ('Таб','\n| A | B |\n|---|---|\n| 1 | 2 |\n',''),
    ];
    return Container(
      height: 44,
      color: cs.surfaceContainerHighest.withOpacity(.35),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        itemCount: btns.length,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (_, i) => ActionChip(
          label: Text(btns[i].$1),
          labelStyle: const TextStyle(fontSize: 12),
          padding: const EdgeInsets.symmetric(horizontal: 4),
          visualDensity: VisualDensity.compact,
          onPressed: () => onMd(btns[i].$2, btns[i].$3),
        ),
      ),
    );
  }
}

// ─── DRAWING ─────────────────────────────────────────────────

class _Pt {
  final Offset offset;
  final bool start;
  final Color color;
  final double width;
  const _Pt({required this.offset, required this.start, required this.color, required this.width});
}

class _Canvas extends StatelessWidget {
  final List<_Pt> pts;
  final Color color;
  final double width;
  final bool eraser;
  final void Function(_Pt) onAdd;
  const _Canvas({required this.pts, required this.color, required this.width, required this.eraser, required this.onAdd});
  @override
  Widget build(BuildContext context) => GestureDetector(
    onPanStart: (d) => onAdd(_Pt(offset: d.localPosition, start: true,
      color: eraser ? Colors.transparent : color, width: eraser ? width * 4 : width)),
    onPanUpdate: (d) => onAdd(_Pt(offset: d.localPosition, start: false,
      color: eraser ? Colors.transparent : color, width: eraser ? width * 4 : width)),
    child: CustomPaint(painter: _Painter(pts), child: const SizedBox.expand()),
  );
}

class _Painter extends CustomPainter {
  final List<_Pt> pts;
  _Painter(this.pts);
  @override
  void paint(Canvas canvas, Size size) {
    for (int i = 0; i < pts.length - 1; i++) {
      if (pts[i + 1].start) continue;
      final p = Paint()
        ..strokeWidth = pts[i].width
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      if (pts[i].color == Colors.transparent) { p..color = Colors.white..blendMode = BlendMode.clear; }
      else { p.color = pts[i].color; }
      canvas.drawLine(pts[i].offset, pts[i + 1].offset, p);
    }
  }
  @override bool shouldRepaint(_Painter _) => true;
}

class _DrawBar extends StatelessWidget {
  final Color color;
  final double width;
  final bool isEraser;
  final void Function(Color) onColor;
  final void Function(double) onWidth;
  final VoidCallback onEraser, onClear;
  const _DrawBar({required this.color, required this.width, required this.isEraser,
    required this.onColor, required this.onWidth, required this.onEraser, required this.onClear});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      color: cs.surfaceContainerHighest.withOpacity(.35),
      child: Row(children: [
        GestureDetector(
          onTap: () => showDialog(context: context, builder: (_) => AlertDialog(
            title: const Text('Цвет кисти'),
            content: BlockPicker(
              pickerColor: color, onColorChanged: onColor,
              availableColors: [
                Colors.black, Colors.white, _purple, _purple2,
                const Color(0xFFBBA4FF), Colors.red, Colors.orange, Colors.green, Colors.blue,
              ]),
            actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
          )),
          child: Container(width: 30, height: 30,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle,
              border: Border.all(color: cs.outline, width: 2))),
        ),
        const SizedBox(width: 8),
        Expanded(child: Slider(value: width, min: 1, max: 24, divisions: 23, onChanged: onWidth)),
        IconButton(
          icon: Icon(isEraser ? Icons.auto_fix_high : Icons.auto_fix_off_outlined),
          color: isEraser ? cs.primary : null, onPressed: onEraser),
        IconButton(icon: const Icon(Icons.delete_sweep_outlined), onPressed: onClear),
      ]),
    );
  }
}

// ─── SHARED ──────────────────────────────────────────────────

class _GradientBg extends StatelessWidget {
  final bool isDark;
  const _GradientBg({required this.isDark});
  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(gradient: LinearGradient(
      begin: Alignment.topLeft, end: Alignment.bottomRight,
      colors: isDark
        ? [_bgDark, const Color(0xFF130020), _bgDark]
        : [const Color(0xFFF8F5FF), const Color(0xFFF0E8FF), Colors.white],
    )),
  );
}

class _Sheet extends StatelessWidget {
  final List<Widget> children;
  const _Sheet({required this.children});
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          decoration: BoxDecoration(
            color: isDark ? Colors.white.withOpacity(.08) : Colors.white.withOpacity(.88),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            border: Border.all(color: _purple.withOpacity(.14))),
          child: SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 36, height: 4, margin: const EdgeInsets.only(top: 10, bottom: 4),
              decoration: BoxDecoration(color: Colors.grey.withOpacity(.35), borderRadius: BorderRadius.circular(2))),
            ...children,
            const SizedBox(height: 8),
          ])),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.note_outlined, size: 72, color: cs.outline.withOpacity(.35)),
      const SizedBox(height: 12),
      Text('Нет заметок', style: TextStyle(color: cs.outline, fontSize: 17, fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      Text('Нажми + чтобы создать', style: TextStyle(color: cs.outline.withOpacity(.6), fontSize: 13)),
    ]));
  }
}

PageRoute _slideRoute(Widget page) => PageRouteBuilder(
  transitionDuration: const Duration(milliseconds: 380),
  pageBuilder: (_, __, ___) => page,
  transitionsBuilder: (_, anim, __, child) => FadeTransition(
    opacity: CurvedAnimation(parent: anim, curve: Curves.easeOut),
    child: SlideTransition(
      position: Tween(begin: const Offset(0, 0.05), end: Offset.zero)
        .animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
      child: child),
  ),
);
