import SwiftUI

// MARK: - Search (mirrors Search.tsx)

struct SearchView: View {
    @StateObject private var store = AppStore.shared
    @StateObject private var api = API.shared
    @State private var q = ""
    @State private var submitted = ""
    @State private var items: [VideoCard] = []
    @State private var page = 0
    @State private var pages = 1
    @State private var loading = false

    static let hotTags = ["都市", "逆袭", "古风", "系统", "后宫", "校园", "仙侠", "职场", "大男主", "御姐", "脑洞", "奇幻"]

    var body: some View {
        NavigationStack {
            List {
                if submitted.isEmpty {
                    Section("搜索历史") {
                        ForEach(store.searchHist, id: \.self) { h in
                            Button(h) { submit(h) }
                        }
                    }
                    Section("热门题材") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))]) {
                            ForEach(Self.hotTags, id: \.self) { t in
                                Button(t) { submit(t) }
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                            }
                        }
                    }
                } else {
                    Section("「\(submitted)」共 \(items.count) 条结果") {
                        ForEach(items) { v in
                            NavigationLink(v.title) { FeedFromList(items: items, start: v.id) }
                        }
                        if loading { ProgressView() }
                        else if page < pages {
                            Button("加载更多") { Task { await run(submitted, page + 1) } }
                        } else { Text("— 已经到底啦 —").font(.caption) }
                    }
                }
            }
            .searchable(text: $q, prompt: "搜索短剧、作者、题材…")
            .onSubmit(of: .search) { submit(q) }
            .navigationTitle("搜索")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink("排行榜") { RankView() }
                }
            }
        }
    }

    func submit(_ k: String) {
        let t = k.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        submitted = t
        store.addSearch(t)
        items = []; pages = 1
        Task { await run(t, 1) }
    }

    func run(_ keyword: String, _ p: Int) async {
        guard !loading else { return }
        loading = true; defer { loading = false }
        do {
            let res = try await api.search(q: keyword, page: p, size: 20)
            let seen = Set(items.map(\.id))
            items += res.items.filter { !seen.contains($0.id) }
            page = p; pages = res.pagination.pages
        } catch { }
    }
}

struct FeedFromList: View {
    var items: [VideoCard]
    var start: Int
    var body: some View {
        FeedPager(items: items, onNearEnd: {})
    }
}

// MARK: - Rank (mirrors RankPage in Search.tsx)

struct RankView: View {
    @StateObject private var api = API.shared
    @State private var kind = "hot"
    @State private var items: [RankItem] = []
    @State private var loading = true

    var body: some View {
        List {
            Picker("榜单", selection: $kind) {
                Text("热播榜").tag("hot")
                Text("推荐榜").tag("recommend")
                Text("潜力榜").tag("potential")
            }
            .pickerStyle(.segmented)
            .listRowSeparator(.hidden)

            ForEach(items) { r in
                HStack {
                    Text("\(r.rank)").font(.headline.monospacedDigit()).frame(width: 30)
                    AsyncImage(url: URL(string: r.cover)) { (img: Image) in img.resizable() } placeholder: {
                        Color.gray.opacity(0.2)
                    }.frame(width: 50, height: 70).clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading) {
                        Text(r.title).font(.subheadline)
                        Text(r.metric_label + " " + fmt(Int(r.metric_value))).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task { await load() }
        .onChange(of: kind) { _ in Task { await load() } }
    }

    func load() async {
        loading = true
        if let res = try? await api.rank(kind: kind) { items = res.items }
        loading = false
    }
}

// MARK: - Category (mirrors Category.tsx)

struct CategoryView: View {
    @StateObject private var api = API.shared
    @State private var rows: [String: [VideoCard]] = [:]
    @State private var posts: [Post] = []

    static let channels = [
        (cate: "ai-duanju", name: "AI成人短剧", desc: "高能反转 · 一口气看完"),
        (cate: "ai-manju", name: "AI成人漫剧", desc: "国创漫剧 · 每周更新"),
        (cate: "ai-huanlian", name: "AI换脸", desc: "换脸演绎 · 全新剧情"),
        (cate: "ai-mogai", name: "AI魔改", desc: "魔改名场面 · 脑洞大开"),
    ]

    var body: some View {
        NavigationStack {
            List {
                NavigationLink("排行榜") { RankView() }
                NavigationLink("黄果吃瓜") { PostsListView() }
                ForEach(Self.channels, id: \.cate) { ch in
                    Section(ch.name) {
                        ForEach(rows[ch.cate] ?? []) { v in
                            NavigationLink(v.title) { FeedPager(items: [v], onNearEnd: {}) }
                        }
                    }
                }
            }
            .navigationTitle("分类")
            .task {
                for ch in Self.channels {
                    if let res = try? await api.category(cate: ch.cate, page: 1, size: 8) {
                        rows[ch.cate] = res.items
                    }
                }
                if let res = try? await api.posts(page: 1, size: 8) { posts = res.items }
            }
        }
    }
}

// MARK: - Posts (mirrors Posts.tsx)

struct PostsListView: View {
    @StateObject private var api = API.shared
    @State private var items: [Post] = []
    @State private var page = 0

    var body: some View {
        List(items) { p in
            NavigationLink(p.title) { PostDetailView(post: p) }
        }
        .navigationTitle("黄果吃瓜")
        .task { await loadMore() }
    }

    func loadMore() async {
        do {
            let res = try await api.posts(page: page + 1, size: 20)
            let seen = Set(items.map(\.id))
            items += res.items.filter { !seen.contains($0.id) }
            page += 1
        } catch { }
    }
}

struct PostDetailView: View {
    var post: Post
    @State private var detail: PostDetail?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(post.title).font(.title2).bold()
                if let c = detail?.content ?? post.content {
                    Text(c).font(.body)
                }
            }
            .padding()
        }
        .task { detail = try? await API.shared.post(id: post.id) }
    }
}

// MARK: - Profile (mirrors Profile.tsx)

struct ProfileView: View {
    @StateObject private var api = API.shared
    @StateObject private var store = AppStore.shared
    @State private var cards: [Detail] = []
    @State private var tab: Int = 0 // 0=fav, 1=history

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let u = api.user {
                        HStack {
                            Text(u.nickname).font(.headline)
                            Spacer()
                            Text("@\(u.username) · ID \(u.id)").font(.caption).foregroundStyle(.secondary)
                            Button("退出") { Task { await api.logout() } }
                        }
                    } else {
                        Button { store.loginOpen = true } label: {
                            HStack {
                                Text("未登录")
                                Spacer()
                                Text("登录").font(.caption).padding(.horizontal, 10).padding(.vertical, 4)
                                    .background(.blue, in: Capsule()).foregroundStyle(.white)
                            }
                        }
                    }
                }
                Section {
                    Picker("内容", selection: $tab) {
                        Text("我的收藏").tag(0)
                        Text("观看历史").tag(1)
                    }.pickerStyle(.segmented)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))]) {
                        ForEach(cards, id: \.id) { c in
                            AsyncImage(url: URL(string: c.cover)) { phase in
                                if let img = phase.image {
                                    img.resizable()
                                } else {
                                    Color.gray
                                }
                            }
                                .aspectRatio(3/4, contentMode: .fill)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                Section {
                    NavigationLink("设置") { SettingsView() }
                }
            }
            .navigationTitle("我的")
            .task { await loadCards() }
            .onChange(of: tab) { _ in Task { await loadCards() } }
        }
    }

    var ids: [Int] { tab == 0 ? store.favs : store.history.map(\.id) }

    func loadCards() async {
        cards = []
        for id in Array(ids.prefix(12)) {
            if let d = try? await api.video(id: id) { cards.append(d) }
        }
    }
}

// MARK: - Settings (mirrors Settings.tsx)

struct SettingsView: View {
    @StateObject private var api = API.shared
    @StateObject private var store = AppStore.shared
    @State private var checking = false
    @State private var update: API.UpdateInfo?
    @State private var showLines = false

    var body: some View {
        List {
            Section("外观") {
                Toggle("深色外观", isOn: Binding(
                    get: { store.theme == .dark },
                    set: { store.theme = $0 ? .dark : .light }))
            }
            Section("本地数据") {
                Text("\(store.favs.count) 部收藏 · \(store.history.count) 条观看记录")
                Button("清理缓存") {
                    Task { await CoverLoader.shared.clearCaches() }
                }
            }
            Section("网络") {
                Button("线路") { showLines = true }
                Toggle("严格安全模式", isOn: Binding(
                    get: { api.strictSecurity },
                    set: { api.setStrictSecurity($0) }))
                Button(checking ? "检查中…" : "检查更新") {
                    checking = true
                    Task {
                        update = try? await api.checkUpdate()
                        checking = false
                    }
                }
                if let u = update {
                    Text(u.has_update ? "有新版本 v\(u.latest)" : "已是最新版本 v\(u.current)")
                        .font(.caption)
                }
            }
            Section("关于") {
                Text("HGhub · v1.1.0 · 个人非商业使用")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("设置")
        .sheet(isPresented: $showLines) { LinePickerView() }
    }
}

// MARK: - Line picker (mirrors LinePicker.tsx)

struct LinePickerView: View {
    @StateObject private var api = API.shared
    @State private var mirrors: [LineItem] = []
    @State private var probes: [String: LineProbe] = [:]
    @State private var loading = false
    @State private var probing = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("固定线路") {
                    ForEach(HGLine.fixed, id: \.url) { f in
                        Button {
                            try? api.setBase(f.url); dismiss()
                        } label: {
                            HStack {
                                Text(f.name)
                                Spacer()
                                if api.base == f.url { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }
                Section("镜像线路") {
                    if loading { ProgressView() }
                    ForEach(mirrors) { m in
                        Button {
                            try? api.setBase(m.url); dismiss()
                        } label: {
                            HStack {
                                Text(m.host ?? m.url).font(.caption)
                                Spacer()
                                if probing {
                                    ProgressView()
                                } else if let p = probes[m.url] {
                                    Text(p.ok ? "\(p.ms)ms" : "不可达").font(.caption2)
                                        .foregroundStyle(p.ok ? .green : .red)
                                }
                                if api.base == m.url { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }
            }
            .navigationTitle("线路")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("刷新") { Task { await refresh() } }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(probing ? "测速中…" : "探测") {
                        guard !probing else { return }
                        Task { await probeAll() }
                    }
                }
            }
            .task { await refresh() }
        }
    }

    func refresh() async {
        loading = true
        if let m = try? await api.lineMirrors() { mirrors = m.items }
        loading = false
    }
    func probeAll() async {
        // v1.2.0: visible probing state (mirrors LNPANDY's probe spinner);
        // per-probe 8s timeout now lives in API.probeOne.
        probing = true
        let results = await api.lineProbe(urls: mirrors.map(\.url))
        for r in results { probes[r.url] = r }
        probing = false
    }
}

// MARK: - Login (mirrors LoginModal.tsx)

struct LoginView: View {
    @StateObject private var api = API.shared
    @State private var username = ""
    @State private var password = ""
    @State private var email = ""
    @State private var mode = 0 // 0 login, 1 register
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Picker("模式", selection: $mode) {
                    Text("登录").tag(0)
                    Text("注册").tag(1)
                }.pickerStyle(.segmented)
                TextField("用户名", text: $username).autocorrectionDisabled()
                SecureField("密码", text: $password)
                if mode == 1 { TextField("邮箱（可选）", text: $email).keyboardType(.emailAddress) }
                if let e = error { Text(e).foregroundStyle(.red).font(.caption) }
                Button(mode == 0 ? "登录" : "注册") {
                    Task {
                        do {
                            if mode == 0 { _ = try await api.login(username: username, password: password) }
                            else { _ = try await api.register(username: username, password: password, email: email) }
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                }.buttonStyle(.borderedProminent)
            }
            .navigationTitle(mode == 0 ? "登录" : "注册")
        }
    }
}
