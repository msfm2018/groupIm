Erlang + Cowboy + Mnesia 私聊 Demo（服务端）

一、文件
  chat_db.erl        Mnesia 数据层
  chat_registry.erl 在线连接注册表
  login_handler.erl  HTTP 登录
  register_handler.erl HTTP 注册
  ws_handler.erl     WebSocket 消息处理
  imdemo_sup.erl     Supervisor
  imdemo_app.erl     OTP Application

二、演示账号
  admin / 123456
  alice / 123456
  bob   / 123456

默认好友关系：
  admin <-> alice
  admin <-> bob
  alice <-> bob

三、注册接口
  HTTP POST /register
  {"username":"newuser","password":"123456","nickname":"新用户"}
  用户名 3-20 位字母/数字/下划线，密码 6-64 位。注册成功后客户端自动登录。

四、客户端协议

HTTP POST /login
{
  "username": "admin",
  "password": "123456"
}

WebSocket 连接：
  /ws?token=<登录返回的 token>

连接成功后客户端请求好友列表：
{
  "type": "friend_list"
}

单聊：
{
  "type": "chat",
  "to": "alice",
  "message": "你好"
}

请求聊天记录：
{
  "type": "history",
  "friend_id": "alice"
}

添加好友（friend_id 是对方用户名/用户 ID）：
{
  "type": "add_friend",
  "friend_id": "bob"
}

五、编译和启动注意事项
1. 将 .erl 文件放进项目 src 目录。
2. 确保项目已有 Cowboy、jsx 依赖，以及正确的 Cowboy 路由：
      {"/login", login_handler, []}
      {"/register", register_handler, []}
      {"/ws", ws_handler, []}
3. 确保 rebar.config / .app.src 中包含本项目已有依赖和模块。
4. 重新编译并启动 OTP application。
5. 第一次启动会创建 Mnesia schema 和表，数据保存在当前 Erlang 节点的 Mnesia 数据目录中。
6. 不要在运行中随意删除 Mnesia 数据目录，否则好友和消息记录会丢失。

六、重要说明
- 这是单节点开发版，Mnesia 使用本地 disc_copies。
- 示例账号密码仅用于开发测试；当前密码使用 SHA-256 摘要，正式产品应使用带盐的 Argon2id/bcrypt 等密码哈希方案。
- Token 当前没有过期时间和注销清理；上线前应补充有效期、HTTPS/WSS、限流和权限控制。
- 离线消息已经写入 messages 表；本版尚未实现离线消息投递队列/已读回执。
- 同一用户重复连接时，新连接会替换旧连接。
- Mnesia 表结构首次创建后，后续修改 attributes 需要做 schema migration，不能只改代码。
