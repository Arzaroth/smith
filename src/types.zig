//! The parts of Forgejo's API objects smith reads. Unknown fields are
//! ignored when decoding; `--json` prints the objects as the API sent them.

pub const User = struct {
    login: []const u8,
    full_name: ?[]const u8 = null,
};

pub const Label = struct {
    id: i64,
    name: []const u8,
    color: ?[]const u8 = null,
    description: ?[]const u8 = null,
    exclusive: bool = false,
};

pub const Repository = struct {
    id: i64 = 0,
    name: []const u8,
    full_name: []const u8,
    owner: ?User = null,
    description: ?[]const u8 = null,
    html_url: []const u8,
    ssh_url: ?[]const u8 = null,
    clone_url: ?[]const u8 = null,
    default_branch: ?[]const u8 = null,
    fork: bool = false,
    parent: ?*const Repository = null,
    private: bool = false,
    archived: bool = false,
    stars_count: i64 = 0,
    forks_count: i64 = 0,
    open_issues_count: i64 = 0,
    open_pr_counter: i64 = 0,
    default_merge_style: ?[]const u8 = null,
    updated_at: ?[]const u8 = null,
};

pub const Branch = struct {
    label: ?[]const u8 = null,
    ref: []const u8,
    sha: []const u8,
    repo: ?Repository = null,
};

pub const PullRequest = struct {
    number: i64,
    title: []const u8,
    body: ?[]const u8 = null,
    state: []const u8,
    user: ?User = null,
    html_url: []const u8,
    head: Branch,
    base: Branch,
    merged: bool = false,
    mergeable: bool = false,
    draft: bool = false,
    labels: ?[]const Label = null,
    assignees: ?[]const User = null,
    requested_reviewers: ?[]const User = null,
    comments: i64 = 0,
    additions: ?i64 = null,
    deletions: ?i64 = null,
    changed_files: ?i64 = null,
    created_at: ?[]const u8 = null,
    updated_at: ?[]const u8 = null,
};

pub const Issue = struct {
    number: i64,
    title: []const u8,
    body: ?[]const u8 = null,
    state: []const u8,
    user: ?User = null,
    html_url: []const u8,
    labels: ?[]const Label = null,
    assignees: ?[]const User = null,
    comments: i64 = 0,
    created_at: ?[]const u8 = null,
    updated_at: ?[]const u8 = null,
};

pub const Comment = struct {
    id: i64,
    user: ?User = null,
    body: []const u8,
    created_at: ?[]const u8 = null,
};

pub const CommitStatus = struct {
    context: []const u8,
    status: []const u8,
    description: ?[]const u8 = null,
    target_url: ?[]const u8 = null,
    created_at: ?[]const u8 = null,
    updated_at: ?[]const u8 = null,
};

pub const CombinedStatus = struct {
    state: []const u8,
    sha: []const u8,
    total_count: i64 = 0,
    statuses: ?[]const CommitStatus = null,
};

pub const ActionRun = struct {
    id: i64,
    index_in_repo: i64 = 0,
    title: []const u8,
    status: []const u8,
    workflow_id: []const u8 = "",
    prettyref: []const u8 = "",
    event: []const u8 = "",
    trigger_event: []const u8 = "",
    commit_sha: []const u8 = "",
    html_url: []const u8,
    created: ?[]const u8 = null,
    started: ?[]const u8 = null,
    stopped: ?[]const u8 = null,
    trigger_user: ?User = null,
};

pub const ActionRunJob = struct {
    id: i64,
    name: []const u8,
    status: []const u8,
    run_id: i64 = 0,
    task_id: i64 = 0,
    attempt: i64 = 0,
};

pub const Version = struct {
    version: []const u8,
};

pub const Attachment = struct {
    id: i64,
    name: []const u8,
    size: i64 = 0,
    download_count: i64 = 0,
    browser_download_url: []const u8 = "",
};

pub const Release = struct {
    id: i64,
    tag_name: []const u8,
    name: ?[]const u8 = null,
    body: ?[]const u8 = null,
    draft: bool = false,
    prerelease: bool = false,
    html_url: []const u8 = "",
    target_commitish: ?[]const u8 = null,
    created_at: ?[]const u8 = null,
    published_at: ?[]const u8 = null,
    author: ?User = null,
    assets: ?[]const Attachment = null,
};

pub const Milestone = struct {
    id: i64,
    title: []const u8,
    description: ?[]const u8 = null,
    state: []const u8 = "open",
    open_issues: i64 = 0,
    closed_issues: i64 = 0,
    due_on: ?[]const u8 = null,
};
