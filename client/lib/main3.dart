import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:rxflare/rxflare.dart';
import 'package:rxws/rxws.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(const MyApp());
}

// Android 模拟器访问电脑本机：10.0.2.2
// 真机请改成电脑的局域网 IP。
const String httpBase = 'http://127.0.0.1:8080';
const String wsBase = 'ws://127.0.0.1:8080/ws';

/// 公共群聊的特殊 ID（与后端 __group__ 对应）
const String groupPeerId = '__group__';

/// 消息类型。图片/视频消息在服务端仍是普通文本，
/// 内容形如 `[img]/files/xxx.jpg`、`[video]/files/xxx.mp4`。
enum MsgKind { text, image, video }

const String imgPrefix = '[img]';
const String videoPrefix = '[video]';
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
    return MsgKind.text;
  }

  /// 图片/视频的完整 URL（服务端返回相对路径，这里拼上服务器地址）
  String get mediaUrl {
    final prefix = kind == MsgKind.image ? imgPrefix : videoPrefix;
    final path = message.substring(prefix.length).trim();
    return path.startsWith('http') ? path : '$httpBase$path';
  }
}

class ChatController {
  final username = ''.obs;
  final nickname = ''.obs;
  final token = ''.obs;

  final status = '未登录'.obs;
  final connected = false.obs;
  final loggedIn = false.obs;
  final uploading = false.obs;

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
        body: jsonEncode({
          'username': name,
          'password': password,
        }),
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

  Future<void> register(String name, String password, String displayName) async {
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

      final data = jsonDecode(
        utf8.decode(response.bodyBytes),
      );
      print(data);
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

      final uri = Uri.parse(wsBase).replace(
        queryParameters: {'token': token.value},
      );

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
      _ws?.sendJson({
        'type': 'history',
        'room': 'group',
      });
    } else {
      _ws?.sendJson({
        'type': 'history',
        'friend_id': friendId,
      });
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

          messages.add(ChatMessage(
            from: from,
            to: to,
            peerId: peerId,
            message: (data['message'] ?? '').toString(),
            timestamp: (data['timestamp'] ?? 0) as int,
          ));

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

            messages.add(ChatMessage(
              from: from,
              to: to,
              peerId: peerId,
              message: row['message'].toString(),
              timestamp: (row['timestamp'] ?? 0) as int,
            ));
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
      _ws?.sendJson({
        'type': 'chat',
        'message': content,
      });
    } else {
      // 私聊：指定接收者
      _ws?.sendJson({
        'type': 'chat',
        'to': friendId,
        'message': content,
      });
    }

    // 本地先显示，服务端负责保存和转发。
    messages.add(ChatMessage(
      from: username.value,
      to: isGroup ? groupPeerId : friendId,
      peerId: friendId,
      message: content,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    ));
    return true;
  }

  /// 选择图片/视频 → HTTP 上传 → 把返回的 URL 作为聊天消息发出
  Future<void> sendMedia(MsgKind kind) async {
    if (uploading.value) return;
    if (!connected.value) {
      status.value = 'WebSocket 尚未连接';
      return;
    }
    if (selectedFriend.value.isEmpty) {
      status.value = '请先从右侧选择聊天对象（公共群聊或用户）';
      return;
    }

    try {
      final file = await FilePicker.pickFile(
        type: kind == MsgKind.image ? FileType.image : FileType.video,
      );
      if (file == null) return; // 用户取消

      uploading.value = true;
      status.value = '正在上传 ${file.name} ...';

      final uri = Uri.parse('$httpBase/upload')
          .replace(queryParameters: {'token': token.value});
      final request = http.MultipartRequest('POST', uri);

      if (kIsWeb) {
        // 仅 Web 走这里；用 dynamic 避免不同版本的 PlatformFile 字段差异导致编译失败
        final Uint8List? bytes = (file as dynamic).bytes as Uint8List?;
        if (bytes == null) {
          status.value = '读取文件失败';
          return;
        }
        if (bytes.length > maxUploadBytes) {
          status.value = '文件不能超过 ${maxUploadBytes ~/ 1024 ~/ 1024}MB';
          return;
        }
        request.files.add(http.MultipartFile.fromBytes(
          'file',
          bytes,
          filename: file.name,
        ));
      } else {
        final path = file.path;
        if (path == null) {
          status.value = '读取文件失败';
          return;
        }
        final part = await http.MultipartFile.fromPath(
          'file',
          path,
          filename: file.name,
        );
        if (part.length > maxUploadBytes) {
          status.value = '文件不能超过 ${maxUploadBytes ~/ 1024 ~/ 1024}MB';
          return;
        }
        request.files.add(part);
      }

      final streamed = await request.send();
      final body = await streamed.stream.bytesToString();
      final data = jsonDecode(body) as Map<String, dynamic>;

      if (streamed.statusCode != 200 || data['code'] != 0) {
        status.value = (data['msg'] ?? '上传失败').toString();
        return;
      }

      final url = data['url'].toString();
      final isVideo = data['kind'] == 'video';
      _sendContent('${isVideo ? videoPrefix : imgPrefix}$url');
    } catch (e) {
      status.value = '上传异常：$e';
    } finally {
      uploading.value = false;
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
    await disconnect();
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: '局域网即时通讯',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
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

  final usernameController = TextEditingController(text: 'admin');
  final passwordController = TextEditingController(text: '123456');
  final nicknameController = TextEditingController();
  bool registerMode = false;
  final messageController = TextEditingController();

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('局域网即时通讯'),
        actions: [
          IconButton(
            tooltip: '退出登录',
            onPressed: chat.disconnect,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: Rx(() {
        if (!chat.loggedIn.value) {
          return loginView();
        }
        return chatView();
      }),
    );
  }

  Widget loginView() {
    return Center(
      child: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.forum, size: 76, color: Colors.blue),
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
    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
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
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: Row(
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
                  color: Theme.of(context).colorScheme.surfaceContainerLow,
                  border: Border(
                    left: BorderSide(
                      color: Theme.of(context).dividerColor,
                    ),
                  ),
                ),
                child: friendPanel(),
              ),
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

      return ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: visibleMessages.length,
        itemBuilder: (context, index) {
          final item = visibleMessages[index];
          final mine = item.isMine(chat.username.value);

          return Align(
            alignment:
                mine ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              constraints: const BoxConstraints(maxWidth: 360),
              margin: const EdgeInsets.symmetric(vertical: 5),
              padding: const EdgeInsets.all(11),
              decoration: BoxDecoration(
                color: mine
                    ? Theme.of(context).colorScheme.primaryContainer
                    : Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
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

  Widget messageInput() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Row(
          children: [
            Obx(() => chat.uploading.value
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    ),
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: '发送图片',
                        onPressed: () => chat.sendMedia(MsgKind.image),
                        icon: const Icon(Icons.image_outlined),
                      ),
                      IconButton(
                        tooltip: '发送视频',
                        onPressed: () => chat.sendMedia(MsgKind.video),
                        icon: const Icon(Icons.videocam_outlined),
                      ),
                    ],
                  )),
            Expanded(
              child: TextField(
                controller: messageController,
                minLines: 1,
                maxLines: 4,
                decoration: const InputDecoration(
                  hintText: '输入消息...',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => send(),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: send,
              child: const Text('发送'),
            ),
          ],
        ),
      ),
    );
  }

  Widget friendPanel_() {
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
                ListTile(
                  selected: groupSelected,
                  leading: CircleAvatar(
                    radius: 18,
                    backgroundColor: Theme.of(context)
                        .colorScheme
                        .primaryContainer,
                    child: const Icon(Icons.groups, size: 20),
                  ),
                  title: const Text(
                    '公共群聊',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: const Text('所有在线用户可见'),
                  onTap: () => chat.selectGroup(),
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

                    return ListTile(
                      selected: selected,
                      leading: CircleAvatar(
                        radius: 18,
                        child: Text(name.isNotEmpty ? name[0] : '?'),
                      ),
                      title: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: const Row(
                        children: [
                          Icon(Icons.circle, size: 8, color: Colors.green),
                          SizedBox(width: 5),
                          Text('在线'),
                        ],
                      ),
                      trailing: count > 0
                          ? Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.red,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                count > 99 ? '99+' : '$count',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                ),
                              ),
                            )
                          : null,
                      onTap: () => chat.selectFriend(id),
                    );
                  }),
              ],
            );
          }),
        ),
      ],
    );
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
                  onTap: () => chat.selectGroup(),
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
                      onTap: () => chat.selectFriend(id),
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
                          fontWeight:
                              selected ? FontWeight.w600 : FontWeight.normal,
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
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                      ),
                    ),
                  ),
                if (selected)
                  Icon(
                    Icons.check_circle,
                    color: scheme.primary,
                    size: 22,
                  ),
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
          constraints: const BoxConstraints(maxWidth: 260, maxHeight: 300),
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
    return GestureDetector(
      onTap: () {
        showDialog(
          context: context,
          builder: (_) => VideoPlayerDialog(url: url),
        );
      },
      child: Container(
        width: 240,
        height: 150,
        decoration: BoxDecoration(
          color: Colors.black87,
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.play_circle_fill, size: 52, color: Colors.white),
            SizedBox(height: 6),
            Text('视频，点击播放',
                style: TextStyle(color: Colors.white70, fontSize: 12)),
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
