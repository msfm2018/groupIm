import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:rxflare/rxflare.dart';
import 'package:rxws/rxws.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart'
    show AudioRecorder, RecordConfig, AudioEncoder;
import 'package:url_launcher/url_launcher.dart';

void main() async{
  WidgetsFlutterBinding.ensureInitialized();
  // 移动端强制竖屏，禁止横屏
  if (!kIsWeb) {
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp, // 只允许正向竖屏
      // DeviceOrientation.portraitDown, // 如果需要倒立竖屏再打开
    ]);
  }
  MediaKit.ensureInitialized();
  runApp(const MyApp());
}

// Android 模拟器访问电脑本机：10.0.2.2
// 真机请改成电脑的局域网 IP。
// const String httpBase = 'http://127.0.0.1:8080';
// const String wsBase = 'ws://127.0.0.1:8080/ws';
const String httpBase = 'http://8.140.51.191:8080';
const String wsBase = 'ws://8.140.51.191:8080/ws';

/// 公共群聊的特殊 ID（与后端 __group__ 对应）
const String groupPeerId = '__group__';

/// 消息类型。图片/视频消息在服务端仍是普通文本，
/// 内容形如 `[img]/files/xxx.jpg`、`[video]/files/xxx.mp4`。
enum MsgKind { text, image, video, file, voice }

const String imgPrefix = '[img]';
const String videoPrefix = '[video]';
const String filePrefix = '[file]'; // [file]/files/x.pdf|原文件名|字节数
const String voicePrefix = '[voice]'; // [voice]/files/x.m4a|秒数

String fmtSize(int bytes) {
  if (bytes < 1024) return '${bytes}B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)}MB';
}

const int maxUploadBytes = 100 * 1024 * 1024; // 与服务端限制一致

class ChatMessage {
  final String from;
  final String to;
  final String peerId;
  final String message;
  final int timestamp;

  ChatMessage({
    required this.from,
    required this.to,
    required this.peerId,
    required this.message,
    required this.timestamp,
  });

  bool isMine(String myId) => from == myId;

  MsgKind get kind {
    if (message.startsWith(imgPrefix)) return MsgKind.image;
    if (message.startsWith(videoPrefix)) return MsgKind.video;
    if (message.startsWith(filePrefix)) return MsgKind.file;
    if (message.startsWith(voicePrefix)) return MsgKind.voice;
    return MsgKind.text;
  }

  String get _prefix {
    switch (kind) {
      case MsgKind.image:
        return imgPrefix;
      case MsgKind.video:
        return videoPrefix;
      case MsgKind.file:
        return filePrefix;
      case MsgKind.voice:
        return voicePrefix;
      case MsgKind.text:
        return '';
    }
  }

  /// 去掉前缀后的内容，用 | 分隔：url|附加信息...
  List<String> get _parts =>
      message.substring(_prefix.length).trim().split('|');

  /// 媒体完整 URL（服务端返回相对路径，这里拼上服务器地址）
  String get mediaUrl {
    final path = _parts.first;
    return path.startsWith('http') ? path : '$httpBase$path';
  }

  int get voiceSeconds => _parts.length > 1 ? int.tryParse(_parts[1]) ?? 0 : 0;

  String get fileName =>
      _parts.length > 2 ? _parts.sublist(1, _parts.length - 1).join('|') : '文件';

  int get fileSize => _parts.length > 2 ? int.tryParse(_parts.last) ?? 0 : 0;
}

class ChatController {
  final username = ''.obs;
  final nickname = ''.obs;
  final token = ''.obs;

  final status = '未登录'.obs;
  final connected = false.obs;
  final loggedIn = false.obs;
  final uploading = false.obs;

  // 语音录制状态
  final recording = false.obs;
  final cancelling = false.obs; // 手指上滑到取消区
  final recordSeconds = 0.obs;
  AudioRecorder? _recorder;
  Timer? _recordTimer;
  DateTime? _recordStart;
  bool _starting = false;
  bool _stopRequested = false;

  // 在线用户列表（所有已登录用户，可直接私聊）
  final onlineUsers = <Map<String, dynamic>>[].obsList;
  final messages = <ChatMessage>[].obsList;
  final selectedFriend = ''.obs;

  /// 私聊未读数量：userId -> count
  final unread = <String, int>{}.obs;

  WsClient? _ws;

  StreamSubscription? _messageSub;
  StreamSubscription? _openSub;
  StreamSubscription? _closeSub;
  StreamSubscription? _errorSub;
  StreamSubscription? _stateSub;

  Future<void> login(String name, String password) async {
    try {
      status.value = '正在登录...';

      final response = await http.post(
        Uri.parse('$httpBase/login'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'username': name, 'password': password}),
      );

      final data = jsonDecode(response.body);

      if (response.statusCode != 200 || data['code'] != 0) {
        status.value = data['msg'] ?? '登录失败';
        return;
      }

      username.value = data['user_id'] ?? data['user'];
      nickname.value = data['nickname'] ?? username.value;
      token.value = data['token'];

      loggedIn.value = true;
      await connect();
    } catch (e) {
      status.value = '登录异常：$e';
    }
  }

  Future<void> register(
    String name,
    String password,
    String displayName,
  ) async {
    try {
      status.value = '正在创建账号...';
      final response = await http.post(
        Uri.parse('$httpBase/register'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'username': name,
          'password': password,
          'nickname': displayName,
        }),
      );

      final data = jsonDecode(utf8.decode(response.bodyBytes));
      if ((response.statusCode != 200 && response.statusCode != 201) ||
          data['code'] != 0) {
        status.value = (data['msg'] ?? '注册失败').toString();
        return;
      }

      status.value = '注册成功，正在登录...';
      await login(name, password);
    } catch (e) {
      status.value = '注册异常：$e';
    }
  }

  Future<void> connect() async {
    try {
      status.value = '正在连接...';

      final client = createWsClient();
      _ws = client;

      _messageSub = client.onMessage.listen(_onMessage);

      _openSub = client.onOpen.listen((_) {
        connected.value = true;
        status.value = 'WebSocket 已连接';
        requestOnlineList();
      });

      _closeSub = client.onClose.listen((_) {
        connected.value = false;
        status.value = '连接已断开';
      });

      _errorSub = client.onError.listen((error) {
        status.value = '连接错误：$error';
      });

      _stateSub = client.onState.listen((state) {
        debugPrint('WebSocket State: $state');
      });

      final uri = Uri.parse(wsBase)
          .replace(queryParameters: {'token': token.value});

      await client.connect(uri.toString());
    } catch (e) {
      connected.value = false;
      status.value = 'WebSocket 连接失败：$e';
    }
  }

  void requestOnlineList() {
    if (!connected.value) return;
    _ws?.sendJson({'type': 'online_list'});
  }

  void selectFriend(String friendId) {
    selectedFriend.value = friendId;
    messages.clear();

    // 打开该会话时清零未读
    if (friendId != groupPeerId && unread.value.containsKey(friendId)) {
      final next = Map<String, int>.from(unread.value);
      next.remove(friendId);
      unread.value = next;
    }

    if (!connected.value) return;

    if (friendId == groupPeerId) {
      _ws?.sendJson({'type': 'history', 'room': 'group'});
    } else {
      _ws?.sendJson({'type': 'history', 'friend_id': friendId});
    }
  }

  /// 选择公共群聊
  void selectGroup() {
    selectFriend(groupPeerId);
  }

  void _upsertOnlineUser(String userId, String nick, {bool online = true}) {
    if (userId == username.value) return;
    for (var i = 0; i < onlineUsers.length; i++) {
      if (onlineUsers[i]['user_id'] == userId) {
        onlineUsers[i] = {
          ...onlineUsers[i],
          'nickname': nick.isNotEmpty ? nick : onlineUsers[i]['nickname'],
          'online': online,
        };
        return;
      }
    }
    if (online) {
      onlineUsers.add({
        'user_id': userId,
        'nickname': nick.isNotEmpty ? nick : userId,
        'online': true,
      });
    }
  }

  void _removeOnlineUser(String userId) {
    onlineUsers.removeWhere((u) => u['user_id'] == userId);
  }

  void _incUnread(String fromId) {
    if (fromId.isEmpty || fromId == username.value) return;
    if (selectedFriend.value == fromId) return; // 正在看这个会话，不算未读
    final next = Map<String, int>.from(unread.value);
    next[fromId] = (next[fromId] ?? 0) + 1;
    unread.value = next;
  }

  void _onMessage(dynamic raw) {
    try {
      if (raw is! String) return;

      final data = jsonDecode(raw) as Map<String, dynamic>;

      switch (data['type']) {
        case 'welcome':
          status.value = '连接成功';
          requestOnlineList();
          break;

        case 'online_list':
        case 'friend_list': // 兼容
          onlineUsers.clear();
          final list = (data['users'] ?? data['friends']) as List? ?? [];
          for (final item in list) {
            final m = Map<String, dynamic>.from(item as Map);
            final id = m['user_id']?.toString() ?? '';
            if (id.isNotEmpty && id != username.value) {
              onlineUsers.add(m);
            }
          }
          if (selectedFriend.value.isEmpty) {
            selectGroup();
          }
          break;

        case 'user_online':
        case 'friend_online':
          _upsertOnlineUser(
            data['user_id']?.toString() ?? '',
            data['nickname']?.toString() ?? '',
            online: true,
          );
          break;

        case 'user_offline':
        case 'friend_offline':
          _removeOnlineUser(data['user_id']?.toString() ?? '');
          break;

        case 'chat':
          final from = (data['from'] ?? '').toString();
          final to = (data['to'] ?? '').toString();
          final room = (data['room'] ?? '').toString();
          final isGroup = room == 'group' || to == groupPeerId;

          final peerId = isGroup
              ? groupPeerId
              : (from == username.value ? to : from);

          messages.add(
            ChatMessage(
              from: from,
              to: to,
              peerId: peerId,
              message: (data['message'] ?? '').toString(),
              timestamp: (data['timestamp'] ?? 0) as int,
            ),
          );

          // 私聊来消息且当前没在看这个人 → 未读 + 状态栏提示
          if (!isGroup && from != username.value) {
            _incUnread(from);
            if (selectedFriend.value != from) {
              String who = from;
              for (final u in onlineUsers.value) {
                if (u['user_id']?.toString() == from) {
                  who = (u['nickname'] ?? from).toString();
                  break;
                }
              }
              status.value = '$who 发来私聊消息';
            }
          }
          break;

        case 'history':
          final list = data['messages'] as List? ?? [];
          final room = (data['room'] ?? '').toString();
          final isGroupHistory = room == 'group';

          for (final item in list) {
            final row = Map<String, dynamic>.from(item as Map);
            final from = row['from'].toString();
            final to = row['to'].toString();
            final peerId = isGroupHistory || to == groupPeerId
                ? groupPeerId
                : (from == username.value ? to : from);

            messages.add(
              ChatMessage(
                from: from,
                to: to,
                peerId: peerId,
                message: row['message'].toString(),
                timestamp: (row['timestamp'] ?? 0) as int,
              ),
            );
          }
          break;

        case 'chat_sent':
          status.value = '消息已发送';
          break;

        case 'chat_queued':
          status.value = '对方当前离线，消息已保存';
          break;

        case 'error':
          status.value = data['msg'] ?? '消息错误';
          break;
      }
    } catch (e) {
      debugPrint('消息解析失败：$e');
    }
  }

  void sendMessage(String text) {
    final content = text.trim();
    if (content.isEmpty) return;
    _sendContent(content);
  }

  /// 发送一条消息（文本或 [img]/[video] 标记），并在本地回显
  bool _sendContent(String content) {
    if (!connected.value) {
      status.value = 'WebSocket 尚未连接';
      return false;
    }

    final friendId = selectedFriend.value;
    if (friendId.isEmpty) {
      status.value = '请先从右侧选择聊天对象（公共群聊或用户）';
      return false;
    }

    final isGroup = friendId == groupPeerId;

    if (isGroup) {
      // 公共群聊：不传 to，后端广播给所有在线用户
      _ws?.sendJson({'type': 'chat', 'message': content});
    } else {
      // 私聊：指定接收者
      _ws?.sendJson({'type': 'chat', 'to': friendId, 'message': content});
    }

    // 本地先显示，服务端负责保存和转发。
    messages.add(
      ChatMessage(
        from: username.value,
        to: isGroup ? groupPeerId : friendId,
        peerId: friendId,
        message: content,
        timestamp: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    return true;
  }

  bool _canSend() {
    if (!connected.value) {
      status.value = 'WebSocket 尚未连接';
      return false;
    }
    if (selectedFriend.value.isEmpty) {
      status.value = '请先从右侧选择聊天对象（公共群聊或用户）';
      return false;
    }
    return true;
  }

  /// 选择图片/视频/文件 → HTTP 上传 → 把结果作为聊天消息发出
  Future<void> sendMedia(MsgKind kind) async {
    if (uploading.value || recording.value) return;
    if (!_canSend()) return;

    try {
      final file = await FilePicker.pickFile(
        type: kind == MsgKind.image
            ? FileType.image
            : kind == MsgKind.video
            ? FileType.video
            : FileType.any,
      );
      if (file == null) return; // 用户取消

      Uint8List? bytes;
      String? path;
      if (kIsWeb) {
        // 用 dynamic 避免不同版本 PlatformFile 字段差异
        bytes = (file as dynamic).bytes as Uint8List?;
      } else {
        path = file.path;
      }
      await _uploadAndSend(name: file.name, path: path, bytes: bytes);
    } catch (e) {
      status.value = '发送异常：$e';
    }
  }

  /// 上传文件并根据服务端返回的类型发送对应消息
  Future<void> _uploadAndSend({
    required String name,
    String? path,
    Uint8List? bytes,
    bool asVoice = false,
    int seconds = 0,
  }) async {
    uploading.value = true;
    status.value = '正在上传 $name ...';
    try {
      final uri = Uri.parse('$httpBase/upload')
          .replace(queryParameters: {'token': token.value});
      final request = http.MultipartRequest('POST', uri);

      if (bytes != null) {
        if (bytes.length > maxUploadBytes) {
          status.value = '文件不能超过 ${maxUploadBytes ~/ 1024 ~/ 1024}MB';
          return;
        }
        request.files.add(
          http.MultipartFile.fromBytes('file', bytes, filename: name),
        );
      } else if (path != null) {
        final part = await http.MultipartFile.fromPath(
          'file',
          path,
          filename: name,
        );
        if (part.length > maxUploadBytes) {
          status.value = '文件不能超过 ${maxUploadBytes ~/ 1024 ~/ 1024}MB';
          return;
        }
        request.files.add(part);
      } else {
        status.value = '读取文件失败';
        return;
      }

      final streamed = await request.send();
      final body = await streamed.stream.bytesToString();
      final data = jsonDecode(body) as Map<String, dynamic>;

      if (streamed.statusCode != 200 || data['code'] != 0) {
        status.value = (data['msg'] ?? '上传失败').toString();
        return;
      }

      final url = data['url'].toString();
      final size = (data['size'] ?? 0) as int;
      var kind = data['kind'].toString();
      // 用户当普通文件选了 mp3 等音频，按文件发送；只有录音才是语音
      if (kind == 'audio' && !asVoice) kind = 'file';

      switch (kind) {
        case 'image':
          _sendContent('$imgPrefix$url');
          break;
        case 'video':
          _sendContent('$videoPrefix$url');
          break;
        case 'audio':
          _sendContent('$voicePrefix$url|$seconds');
          break;
        default:
          final safeName = name.replaceAll('|', '_');
          _sendContent('$filePrefix$url|$safeName|$size');
      }
    } catch (e) {
      status.value = '上传异常：$e';
    } finally {
      uploading.value = false;
    }
  }

  // ---------------- 语音录制：按住录音，松开发送，上滑取消 ----------------

  Future<void> startRecording() async {
    if (recording.value || _starting || uploading.value) return;
    if (!_canSend()) return;

    _starting = true;
    _stopRequested = false;
    cancelling.value = false;
    try {
      final rec = _recorder ??= AudioRecorder();
      if (!await rec.hasPermission()) {
        status.value = '没有麦克风权限';
        return;
      }

      var path = '';
      if (!kIsWeb) {
        final dir = await getTemporaryDirectory();
        path = '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
      }
      await rec.start(
        const RecordConfig(encoder: AudioEncoder.aacLc),
        path: path,
      );

      recording.value = true;
      recordSeconds.value = 0;
      _recordStart = DateTime.now();
      _recordTimer?.cancel();
      _recordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        recordSeconds.value++;
        if (recordSeconds.value >= 60) stopRecording(); // 最长 60 秒
      });
    } catch (e) {
      status.value = '无法录音：$e';
      return;
    } finally {
      _starting = false;
    }

    // 权限弹窗期间用户已经松手
    if (_stopRequested) {
      _stopRequested = false;
      await stopRecording();
    }
  }

  Future<void> stopRecording() async {
    if (_starting) {
      _stopRequested = true;
      return;
    }
    if (!recording.value) return;

    _recordTimer?.cancel();
    recording.value = false;

    final rec = _recorder;
    final ms = DateTime.now()
        .difference(_recordStart ?? DateTime.now())
        .inMilliseconds;
    final cancel = cancelling.value;
    cancelling.value = false;
    if (rec == null) return;

    try {
      if (cancel) {
        await rec.cancel();
        status.value = '已取消发送语音';
        return;
      }
      if (ms < 1000) {
        await rec.cancel();
        status.value = '说话时间太短';
        return;
      }

      final path = await rec.stop();
      if (path == null || path.isEmpty) {
        status.value = '录音失败';
        return;
      }

      final seconds = (ms / 1000).round().clamp(1, 60);
      final name = 'voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
      if (kIsWeb) {
        // Web 返回的是 blob URL，需要取回字节
        final resp = await http.get(Uri.parse(path));
        await _uploadAndSend(
          name: name,
          bytes: resp.bodyBytes,
          asVoice: true,
          seconds: seconds,
        );
      } else {
        await _uploadAndSend(
          name: name,
          path: path,
          asVoice: true,
          seconds: seconds,
        );
      }
    } catch (e) {
      status.value = '语音发送失败：$e';
    }
  }

  Future<void> disconnect() async {
    await _messageSub?.cancel();
    await _openSub?.cancel();
    await _closeSub?.cancel();
    await _errorSub?.cancel();
    await _stateSub?.cancel();

    _ws?.close();
    _ws = null;

    connected.value = false;
    loggedIn.value = false;
    onlineUsers.clear();
    messages.clear();
    selectedFriend.value = '';
    unread.value = {};
    status.value = '已退出';
  }

  Future<void> dispose() async {
    _recordTimer?.cancel();
    await _recorder?.dispose();
    await disconnect();
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final isIOS = defaultTargetPlatform == TargetPlatform.iOS;

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: '局域网即时通讯',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
        // iOS 更圆润一点
        cardTheme: CardThemeData(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(isIOS ? 16 : 12),
          ),
        ),
      ),
      home: const ChatPage(),
    );
  }
}

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final chat = ChatController();
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  final usernameController = TextEditingController(text: 'admin');
  final passwordController = TextEditingController(text: '123456');
  final nicknameController = TextEditingController();
  bool registerMode = false;
  final messageController = TextEditingController();
  bool voiceMode = false; // true：显示“按住 说话”
  double _downY = 0;

  /// 宽屏（桌面 / 平板横屏）阈值
  bool get _isWide => MediaQuery.sizeOf(context).width >= 700;

  bool get _isIOS => Theme.of(context).platform == TargetPlatform.iOS;

  @override
  void dispose() {
    chat.dispose();
    usernameController.dispose();
    passwordController.dispose();
    nicknameController.dispose();
    messageController.dispose();
    super.dispose();
  }

  void send() {
    chat.sendMessage(messageController.text);
    messageController.clear();
  }

  /// 选择聊天对象后，窄屏自动关闭 Drawer
  void _selectAndClose(VoidCallback select) {
    select();
    if (!_isWide) {
      _scaffoldKey.currentState?.closeDrawer();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(
        title: const Text('局域网即时通讯'),
        // 窄屏登录后显示菜单按钮打开在线列表
        leading: Rx(() {
          if (!chat.loggedIn.value || _isWide) return const SizedBox.shrink();
          return IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () => _scaffoldKey.currentState?.openDrawer(),
          );
        }),
        actions: [
          IconButton(
            tooltip: '退出登录',
            onPressed: chat.disconnect,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      // 窄屏用 Drawer 放好友列表
      drawer: Rx(() {
        if (!chat.loggedIn.value || _isWide) return const SizedBox.shrink();
        return Drawer(
          width: math.min(300, MediaQuery.sizeOf(context).width * 0.82),
          child: SafeArea(child: friendPanel()),
        );
      }),
      body: Rx(() {
        if (!chat.loggedIn.value) {
          return loginView();
        }
        return chatView();
      }),
    );
  }

  Widget loginView() {
    final maxW = math.min(360.0, MediaQuery.sizeOf(context).width - 32);

    return Center(
      child: SizedBox(
        width: maxW,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.forum, size: _isWide ? 76 : 64, color: Colors.blue),
              const SizedBox(height: 20),
              TextField(
                controller: usernameController,
                decoration: const InputDecoration(
                  labelText: '用户名',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 14),
              if (registerMode) ...[
                TextField(
                  controller: nicknameController,
                  decoration: const InputDecoration(
                    labelText: '昵称',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 14),
              ],
              TextField(
                controller: passwordController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: '密码（至少 6 位）',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () {
                    final name = usernameController.text.trim();
                    final password = passwordController.text;
                    if (registerMode) {
                      final nickname = nicknameController.text.trim();
                      chat.register(
                        name,
                        password,
                        nickname.isEmpty ? name : nickname,
                      );
                    } else {
                      chat.login(name, password);
                    }
                  },
                  child: Text(registerMode ? '注册并登录' : '登录'),
                ),
              ),
              TextButton(
                onPressed: () => setState(() => registerMode = !registerMode),
                child: Text(registerMode ? '已有账号？返回登录' : '没有账号？立即注册'),
              ),
              const SizedBox(height: 8),
              Obx(() => Text(chat.status.value)),
              if (!registerMode) ...[
                const SizedBox(height: 12),
                const Text(
                  '演示账号：admin / alice / bob\n密码均为：123456',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
Widget chatView() {
  final isWide = _isWide;

  return Stack(
    children: [
      Column(
        children: [
          // 顶部状态条
          Container(
            width: double.infinity,
            padding: EdgeInsets.symmetric(
              horizontal: 14,
              vertical: isWide ? 9 : 7,
            ),
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Row(
              children: [
                Icon(
                  Icons.circle,
                  size: 10,
                  color: chat.connected.value ? Colors.green : Colors.orange,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${chat.nickname.value}  ·  ${chat.status.value}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: isWide ? 14 : 13),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: isWide
                ? Row(
                    children: [
                      Expanded(
                        child: Column(
                          children: [
                            Expanded(child: messageList()),
                            messageInput(),
                          ],
                        ),
                      ),
                      Container(
                        width: 240,
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerLow,
                          border: Border(
                            left: BorderSide(
                              color: Theme.of(context).dividerColor,
                            ),
                          ),
                        ),
                        child: friendPanel(),
                      ),
                    ],
                  )
                : Column(
                    children: [
                      Expanded(child: messageList()),
                      messageInput(),
                    ],
                  ),
          ),
        ],
      ),

      // ========== 微信风格录音浮层 ==========
      Obx(() {
        if (!chat.recording.value) return const SizedBox.shrink();

        final cancel = chat.cancelling.value;
        final sec = chat.recordSeconds.value;

        return Positioned.fill(
          child: IgnorePointer( // 不拦截下面的手势
            child: Container(
              color: Colors.black.withOpacity(0.45),
              alignment: Alignment.center,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 160,
                height: 160,
                decoration: BoxDecoration(
                  color: cancel
                      ? const Color(0xFFE64340)
                      : const Color(0xFF4C4C4C),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      cancel ? Icons.undo_rounded : Icons.mic,
                      size: 48,
                      color: Colors.white,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      cancel ? '松开取消' : '$sec″',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (!cancel) ...[
                      const SizedBox(height: 6),
                      const Text(
                        '上滑取消',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      }),
    ],
  );
}
  Widget chatView111() {
    final isWide = _isWide;

    return Column(
      children: [
        // 顶部状态条
        Container(
          width: double.infinity,
          padding: EdgeInsets.symmetric(
            horizontal: 14,
            vertical: isWide ? 9 : 7,
          ),
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Row(
            children: [
              Icon(
                Icons.circle,
                size: 10,
                color: chat.connected.value ? Colors.green : Colors.orange,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${chat.nickname.value}  ·  ${chat.status.value}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: isWide ? 14 : 13),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: isWide
              ? Row(
                  children: [
                    // 中间：聊天区域
                    Expanded(
                      child: Column(
                        children: [
                          Expanded(child: messageList()),
                          messageInput(),
                        ],
                      ),
                    ),
                    // 右侧：在线用户
                    Container(
                      width: 240,
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .surfaceContainerLow,
                        border: Border(
                          left: BorderSide(
                            color: Theme.of(context).dividerColor,
                          ),
                        ),
                      ),
                      child: friendPanel(),
                    ),
                  ],
                )
              // 窄屏：只有聊天区，列表走 Drawer
              : Column(
                  children: [
                    Expanded(child: messageList()),
                    messageInput(),
                  ],
                ),
        ),
      ],
    );
  }

  Widget messageList() {
    return Obx(() {
      final friendId = chat.selectedFriend.value;
      final visibleMessages = chat.messages
          .where((item) => item.peerId == friendId)
          .toList();

      if (friendId.isEmpty) {
        return const Center(child: Text('请从右侧选择公共群聊或用户'));
      }

      if (visibleMessages.isEmpty) {
        final hint = friendId == groupPeerId
            ? '公共群聊还没有消息，发送一条让所有在线用户看到吧'
            : '还没有聊天记录，发送一条消息吧';
        return Center(child: Text(hint));
      }

      final maxBubbleW = _isWide
          ? 360.0
          : MediaQuery.sizeOf(context).width * 0.78;

      // reverse: true → 列表从底部开始，新消息/图片加载完成后始终停在最底部；
      // key 随会话变化，切换聊天对象时滚动位置自动重置到底部
      return ListView.builder(
        key: ValueKey(friendId),
        reverse: true,
        padding: EdgeInsets.all(_isWide ? 16 : 12),
        itemCount: visibleMessages.length,
        itemBuilder: (context, index) {
          final item = visibleMessages[visibleMessages.length - 1 - index];
          final mine = item.isMine(chat.username.value);

          return Align(
            alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              constraints: BoxConstraints(maxWidth: maxBubbleW),
              margin: const EdgeInsets.symmetric(vertical: 5),
              padding: EdgeInsets.all(_isWide ? 11 : 10),
              decoration: BoxDecoration(
                color: mine
                    ? Theme.of(context).colorScheme.primaryContainer
                    : Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(_isIOS ? 18 : 12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    mine ? '我' : item.from,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                  const SizedBox(height: 4),
                  MessageContent(item: item),
                ],
              ),
            ),
          );
        },
      );
    });
  }

  /// Enter 发送，Shift+Enter 换行（输入法组词时的回车不发送）
  KeyEventResult _onInputKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.enter &&
        !HardwareKeyboard.instance.isShiftPressed &&
        !messageController.value.composing.isValid) {
      send();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget _toolButton(IconData icon, String tip, VoidCallback onTap) {
    return IconButton(
      tooltip: tip,
      onPressed: onTap,
      icon: Icon(icon, size: _isWide ? 24 : 22),
      visualDensity: _isWide ? VisualDensity.standard : VisualDensity.compact,
    );
  }

  Widget messageInput() {
    final theme = Theme.of(context);
    final isWide = _isWide;

    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border(top: BorderSide(color: theme.dividerColor)),
        ),
        padding: EdgeInsets.fromLTRB(isWide ? 12 : 8, 8, isWide ? 12 : 8, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 上：输入框 / 按住说话
            if (voiceMode)
              voiceHoldButton()
            else
              Focus(
                onKeyEvent: _onInputKey,
                child: TextField(
                  controller: messageController,
                  minLines: isWide ? 3 : 1,
                  maxLines: isWide ? 5 : 4,
                  decoration: InputDecoration(
                    hintText: isWide ? 'Enter 发送，Shift+Enter 换行' : '输入消息...',
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(
                      vertical: isWide ? 8 : 6,
                    ),
                  ),
                ),
              ),
            // 下：工具栏
            Row(
              children: [
                _toolButton(
                  Icons.image_outlined,
                  '发送图片',
                  () => chat.sendMedia(MsgKind.image),
                ),
                _toolButton(
                  Icons.videocam_outlined,
                  '发送视频',
                  () => chat.sendMedia(MsgKind.video),
                ),
                _toolButton(
                  Icons.folder_open_outlined,
                  '发送文件',
                  () => chat.sendMedia(MsgKind.file),
                ),
                const Spacer(),
                Obx(
                  () => chat.uploading.value
                      ? const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 10),
                          child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2.5),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
                _toolButton(
                  voiceMode ? Icons.keyboard_alt_outlined : Icons.mic_none,
                  voiceMode ? '切换为文字输入' : '发送语音',
                  () => setState(() => voiceMode = !voiceMode),
                ),
                if (!voiceMode) ...[
                  const SizedBox(width: 6),
                  FilledButton(
                    onPressed: send,
                    style: FilledButton.styleFrom(
                      visualDensity: isWide
                          ? VisualDensity.standard
                          : VisualDensity.compact,
                      padding: EdgeInsets.symmetric(
                        horizontal: isWide ? 16 : 12,
                        vertical: isWide ? 12 : 8,
                      ),
                    ),
                    child: const Text('发送'),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
/// 按住录音，松开发送，上滑取消（接近微信质感）
Widget voiceHoldButton() {
  final scheme = Theme.of(context).colorScheme;

  return Obx(() {
    final rec = chat.recording.value;
    final cancel = chat.cancelling.value;
    final sec = chat.recordSeconds.value;

    // 颜色与文字（微信风格）
    Color bg;
    Color fg;
    String text;
    if (!rec) {
      bg = scheme.surfaceContainerHighest;
      fg = scheme.onSurface;
      text = '按住 说话';
    } else if (cancel) {
      bg = const Color(0xFFE64340); // 微信红
      fg = Colors.white;
      text = '松开手指，取消发送';
    } else {
      bg = const Color(0xFF07C160); // 微信绿
      fg = Colors.white;
      text = '松开 结束';
    }

    return Listener(
      onPointerDown: (e) {
        _downY = e.position.dy;
        // 触感反馈
        HapticFeedback.mediumImpact();
        chat.startRecording();
      },
      onPointerMove: (e) {
        if (chat.recording.value) {
          final up = (_downY - e.position.dy) > 70;
          if (up != chat.cancelling.value) {
            // 进入/离开取消区时再给一次轻触感
            HapticFeedback.selectionClick();
            chat.cancelling.value = up;
          }
        }
      },
      onPointerUp: (_) => chat.stopRecording(),
      onPointerCancel: (_) {
        chat.cancelling.value = true;
        chat.stopRecording();
      },
      child: AnimatedScale(
        scale: rec ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          width: double.infinity,
          height: 54,
          margin: const EdgeInsets.only(bottom: 4),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(8),
            boxShadow: rec
                ? [
                    BoxShadow(
                      color: bg.withOpacity(0.35),
                      blurRadius: 8,
                      offset: const Offset(0, 3),
                    ),
                  ]
                : null,
          ),
          child: Text(
            text,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w500,
              color: fg,
              letterSpacing: 0.5,
            ),
          ),
        ),
      ),
    );
  });
}
  /// 按住录音，松开发送，上滑取消
  Widget voiceHoldButton111() {
    final scheme = Theme.of(context).colorScheme;

    return Obx(() {
      final rec = chat.recording.value;
      final cancel = chat.cancelling.value;
      final sec = chat.recordSeconds.value;

      final color = !rec
          ? scheme.surfaceContainerHighest
          : cancel
          ? Colors.red.shade300
          : scheme.primaryContainer;
      final text = !rec
          ? '按住 说话'
          : cancel
          ? '松开 取消发送'
          : '录音中 $sec″  ·  松开发送，上滑取消';

      return Listener(
        onPointerDown: (e) {
          _downY = e.position.dy;
          chat.startRecording();
        },
        onPointerMove: (e) {
          if (chat.recording.value) {
            chat.cancelling.value = (_downY - e.position.dy) > 60;
          }
        },
        onPointerUp: (_) => chat.stopRecording(),
        onPointerCancel: (_) {
          chat.cancelling.value = true;
          chat.stopRecording();
        },
        child: Container(
          width: double.infinity,
          height: _isWide ? 76 : 64,
          margin: const EdgeInsets.only(bottom: 6),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(_isIOS ? 14 : 8),
          ),
          child: Text(text, style: TextStyle(fontSize: _isWide ? 16 : 15)),
        ),
      );
    });
  }

  Widget friendPanel() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 6, 8),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  '在线用户',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              IconButton(
                tooltip: '刷新在线列表',
                onPressed: chat.requestOnlineList,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: Obx(() {
            final selectedId = chat.selectedFriend.value;
            final groupSelected = selectedId == groupPeerId;
            final unreadMap = chat.unread.value;

            return ListView(
              children: [
                // 公共群聊
                _chatTargetTile(
                  context: context,
                  selected: groupSelected,
                  title: '公共群聊',
                  subtitleWidget: const Text(
                    '所有在线用户可见',
                    style: TextStyle(fontSize: 12),
                  ),
                  leading: CircleAvatar(
                    radius: 18,
                    backgroundColor: Theme.of(context)
                        .colorScheme
                        .primaryContainer,
                    child: const Icon(Icons.groups, size: 20),
                  ),
                  unreadCount: 0,
                  onTap: () => _selectAndClose(chat.selectGroup),
                ),
                const Divider(height: 1),
                if (chat.onlineUsers.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      '暂无其他在线用户\n等其他人登录后即可私聊',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey),
                    ),
                  )
                else
                  ...chat.onlineUsers.map((user) {
                    final id = user['user_id'].toString();
                    final name = (user['nickname'] ?? id).toString();
                    final selected = selectedId == id;
                    final count = unreadMap[id] ?? 0;

                    return _chatTargetTile(
                      context: context,
                      selected: selected,
                      title: name,
                      subtitleWidget: const Row(
                        children: [
                          Icon(Icons.circle, size: 8, color: Colors.green),
                          SizedBox(width: 5),
                          Text('在线', style: TextStyle(fontSize: 12)),
                        ],
                      ),
                      leading: CircleAvatar(
                        radius: 18,
                        child: Text(name.isNotEmpty ? name[0] : '?'),
                      ),
                      unreadCount: count,
                      onTap: () => _selectAndClose(() => chat.selectFriend(id)),
                    );
                  }),
              ],
            );
          }),
        ),
      ],
    );
  }

  /// 右侧聊天对象：选中时左侧色条 + 背景高亮 + 勾选
  Widget _chatTargetTile({
    required BuildContext context,
    required bool selected,
    required String title,
    required Widget subtitleWidget,
    required Widget leading,
    required int unreadCount,
    required VoidCallback onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;

    return Material(
      color: selected
          ? scheme.primaryContainer.withOpacity(0.55)
          : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: selected ? scheme.primary : Colors.transparent,
                width: 3,
              ),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              children: [
                leading,
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.normal,
                        ),
                      ),
                      const SizedBox(height: 2),
                      subtitleWidget,
                    ],
                  ),
                ),
                if (unreadCount > 0 && !selected)
                  Container(
                    margin: const EdgeInsets.only(right: 4),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.red,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      unreadCount > 99 ? '99+' : '$unreadCount',
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ),
                if (selected)
                  Icon(Icons.check_circle, color: scheme.primary, size: 22),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================
// 消息内容：文本 / 图片 / 视频
// ============================================================

class MessageContent extends StatelessWidget {
  final ChatMessage item;
  const MessageContent({super.key, required this.item});

  @override
  Widget build(BuildContext context) {
    switch (item.kind) {
      case MsgKind.image:
        return ImageBubble(url: item.mediaUrl);
      case MsgKind.video:
        return VideoBubble(url: item.mediaUrl);
      case MsgKind.file:
        return FileBubble(
          url: item.mediaUrl,
          name: item.fileName,
          size: item.fileSize,
        );
      case MsgKind.voice:
        return VoiceBubble(url: item.mediaUrl, seconds: item.voiceSeconds);
      case MsgKind.text:
        return Text(item.message);
    }
  }
}

class ImageBubble extends StatelessWidget {
  final String url;
  const ImageBubble({super.key, required this.url});

  Widget _error() => const SizedBox(
    width: 200,
    height: 120,
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.broken_image_outlined, size: 32),
          SizedBox(height: 4),
          Text('图片加载失败', style: TextStyle(fontSize: 12)),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.sizeOf(context).width >= 700;

    return GestureDetector(
      onTap: () {
        showDialog(
          context: context,
          builder: (_) => Dialog.fullscreen(
            backgroundColor: Colors.black,
            child: Stack(
              children: [
                Positioned.fill(
                  child: InteractiveViewer(
                    minScale: 0.5,
                    maxScale: 5,
                    child: Center(
                      child: Image.network(
                        url,
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) => _error(),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: 8,
                  right: 8,
                  child: SafeArea(
                    child: IconButton(
                      color: Colors.white,
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: isWide ? 260 : 220,
            maxHeight: isWide ? 300 : 240,
          ),
          child: Image.network(
            url,
            fit: BoxFit.contain,
            loadingBuilder: (context, child, progress) {
              if (progress == null) return child;
              final total = progress.expectedTotalBytes;
              return SizedBox(
                width: 200,
                height: 120,
                child: Center(
                  child: CircularProgressIndicator(
                    value: total == null
                        ? null
                        : progress.cumulativeBytesLoaded / total,
                  ),
                ),
              );
            },
            errorBuilder: (_, __, ___) => _error(),
          ),
        ),
      ),
    );
  }
}

class VideoBubble extends StatelessWidget {
  final String url;
  const VideoBubble({super.key, required this.url});

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.sizeOf(context).width >= 700;

    return GestureDetector(
      onTap: () {
        showDialog(
          context: context,
          builder: (_) => VideoPlayerDialog(url: url),
        );
      },
      child: Container(
        width: isWide ? 240 : 200,
        height: isWide ? 150 : 120,
        decoration: BoxDecoration(
          color: Colors.black87,
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.play_circle_fill, size: 52, color: Colors.white),
            SizedBox(height: 6),
            Text(
              '视频，点击播放',
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class VideoPlayerDialog extends StatefulWidget {
  final String url;
  const VideoPlayerDialog({super.key, required this.url});

  @override
  State<VideoPlayerDialog> createState() => _VideoPlayerDialogState();
}

class _VideoPlayerDialogState extends State<VideoPlayerDialog> {
  late final Player _player = Player();
  late final VideoController _controller = VideoController(_player);
  String? _error;
  StreamSubscription? _errorSub;

  @override
  void initState() {
    super.initState();
    _errorSub = _player.stream.error.listen((e) {
      if (mounted) setState(() => _error = '播放失败：$e');
    });
    _player.open(Media(widget.url));
  }

  @override
  void dispose() {
    _errorSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog.fullscreen(
      backgroundColor: Colors.black,
      child: Stack(
        children: [
          Positioned.fill(
            child: _error != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        _error!,
                        style: const TextStyle(color: Colors.white),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : Video(controller: _controller),
          ),
          Positioned(
            top: 8,
            right: 8,
            child: SafeArea(
              child: IconButton(
                color: Colors.white,
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// 文件消息：点击用系统浏览器/默认程序下载
// ============================================================

class FileBubble extends StatelessWidget {
  final String url;
  final String name;
  final int size;
  const FileBubble({
    super.key,
    required this.url,
    required this.name,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () async {
        final uri = Uri.parse('$url?name=${Uri.encodeQueryComponent(name)}');
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      },
      child: SizedBox(
        width: 240,
        child: Row(
          children: [
            const Icon(Icons.insert_drive_file_outlined, size: 40),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, maxLines: 2, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text(
                    size > 0 ? '${fmtSize(size)} · 点击下载' : '点击下载',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// 语音消息：点击播放 / 再点停止，同一时间只播放一条
// ============================================================

class VoiceBubble extends StatefulWidget {
  final String url;
  final int seconds;
  const VoiceBubble({super.key, required this.url, required this.seconds});

  @override
  State<VoiceBubble> createState() => _VoiceBubbleState();
}

class _VoiceBubbleState extends State<VoiceBubble> {
  static _VoiceBubbleState? _current;

  Player? _player;
  StreamSubscription? _sub;
  bool _playing = false;

  Future<void> _stop() async {
    await _player?.stop();
    if (mounted) setState(() => _playing = false);
  }

  Future<void> _toggle() async {
    if (_playing) {
      await _stop();
      return;
    }
    if (_current != null && _current != this) {
      await _current!._stop();
    }
    final player = _player ??= Player();
    _sub ??= player.stream.completed.listen((done) {
      if (done && mounted) setState(() => _playing = false);
    });
    _current = this;
    await player.open(Media(widget.url));
    if (mounted) setState(() => _playing = true);
  }

  @override
  void dispose() {
    if (_current == this) _current = null;
    _sub?.cancel();
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final width = (90 + widget.seconds * 3).clamp(90, 220).toDouble();
    return InkWell(
      onTap: _toggle,
      child: SizedBox(
        width: width,
        child: Row(
          children: [
            Icon(
              _playing ? Icons.stop_circle_outlined : Icons.play_circle_outline,
              size: 28,
            ),
            const SizedBox(width: 8),
            Text('${widget.seconds}″'),
          ],
        ),
      ),
    );
  }
}
