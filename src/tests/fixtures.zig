//! Canned Forgejo API objects for the mock.

const std = @import("std");

pub const repo =
    \\{"id":1,"name":"repo","full_name":"owner/repo","owner":{"login":"owner"},"description":"A test repository",
    \\"html_url":"http://forge.test/owner/repo","ssh_url":"git@forge.test:owner/repo.git","clone_url":"http://forge.test/owner/repo.git",
    \\"default_branch":"main","fork":false,"private":false,"archived":false,"stars_count":3,"forks_count":1,
    \\"open_issues_count":2,"open_pr_counter":1,"default_merge_style":"squash","updated_at":"2026-09-29T11:00:00Z"}
;

pub const issue_open =
    \\{"id":10,"number":7,"title":"Crash on start","body":"It crashes.","state":"open","user":{"login":"alice"},
    \\"html_url":"http://forge.test/owner/repo/issues/7","labels":[{"id":1,"name":"bug","color":"ee0701"}],
    \\"assignees":[{"login":"bob"}],"comments":1,"created_at":"2026-09-28T12:00:00Z","updated_at":"2026-09-29T09:00:00Z"}
;

pub const issue_list = "[" ++ issue_open ++ "]";

pub const labels =
    \\[{"id":1,"name":"bug","color":"ee0701"},{"id":2,"name":"ui","color":"00aabb"}]
;

pub const comments =
    \\[{"id":100,"user":{"login":"bob"},"body":"Same here.","created_at":"2026-09-29T10:00:00Z"}]
;

pub const comment =
    \\{"id":101,"user":{"login":"me"},"body":"Thanks","created_at":"2026-09-29T12:00:00Z"}
;

fn headOwner(comptime repo_id: []const u8) []const u8 {
    return if (std.mem.eql(u8, repo_id, "1")) "owner" else "alice";
}

pub fn pull(comptime number: []const u8, comptime title: []const u8, comptime head: []const u8, comptime head_repo_id: []const u8, comptime state: []const u8, comptime merged: []const u8) []const u8 {
    return "{\"id\":2" ++ number ++ ",\"number\":" ++ number ++ ",\"title\":\"" ++ title ++ "\",\"body\":\"Does things.\",\"state\":\"" ++ state ++
        "\",\"user\":{\"login\":\"alice\"},\"html_url\":\"http://forge.test/owner/repo/pulls/" ++ number ++
        "\",\"head\":{\"ref\":\"" ++ head ++ "\",\"sha\":\"abc123\",\"repo\":{\"id\":" ++ head_repo_id ++
        ",\"name\":\"repo\",\"full_name\":\"" ++ headOwner(head_repo_id) ++ "/repo\",\"owner\":{\"login\":\"" ++ headOwner(head_repo_id) ++ "\"},\"html_url\":\"x\"}}" ++
        ",\"base\":{\"ref\":\"main\",\"sha\":\"def456\",\"repo\":{\"id\":1,\"name\":\"repo\",\"full_name\":\"owner/repo\",\"html_url\":\"x\"}}" ++
        ",\"merged\":" ++ merged ++ ",\"mergeable\":true,\"labels\":[],\"comments\":0,\"additions\":10,\"deletions\":2,\"changed_files\":3" ++
        ",\"created_at\":\"2026-09-28T12:00:00Z\",\"updated_at\":\"2026-09-29T11:30:00Z\"}";
}

pub const pr_same = pull("12", "Add feature", "feature", "1", "open", "false");
pub const pr_fork = pull("13", "WIP: Fork change", "patch-1", "5", "open", "false");
pub const pr_merged = pull("14", "Old change", "old", "1", "closed", "true");
pub const pr_closed = pull("15", "Abandoned", "nope", "1", "closed", "false");
pub const pr_list_open = "[" ++ pr_same ++ "," ++ pr_fork ++ "]";
pub const pr_list_closed = "[" ++ pr_merged ++ "," ++ pr_closed ++ "]";

pub const status_mixed =
    \\{"state":"failure","sha":"abc123","total_count":3,"statuses":[
    \\{"context":"ci / build","status":"success","description":"Successful in 1m","target_url":"/owner/repo/actions/runs/1/jobs/0"},
    \\{"context":"ci / test","status":"failure","description":"Failing after 2m","target_url":"/owner/repo/actions/runs/1/jobs/1"},
    \\{"context":"lint","status":"pending","description":"Waiting","target_url":null}]}
;

pub const status_green =
    \\{"state":"success","sha":"abc123","total_count":1,"statuses":[
    \\{"context":"ci / build","status":"success","description":"Successful in 1m","target_url":"/owner/repo/actions/runs/1/jobs/0"}]}
;

pub const status_pending =
    \\{"state":"pending","sha":"abc123","total_count":1,"statuses":[
    \\{"context":"ci / build","status":"pending","description":"Running","target_url":null}]}
;

fn run(comptime id: []const u8, comptime status: []const u8, comptime ref: []const u8) []const u8 {
    return "{\"id\":" ++ id ++ ",\"index_in_repo\":" ++ id ++ ",\"title\":\"Run " ++ id ++ "\",\"status\":\"" ++ status ++
        "\",\"workflow_id\":\"ci.yml\",\"prettyref\":\"" ++ ref ++ "\",\"event\":\"push\",\"commit_sha\":\"abc123\"" ++
        ",\"html_url\":\"http://forge.test/owner/repo/actions/runs/" ++ id ++ "\",\"created\":\"2026-09-29T11:00:00Z\"" ++
        ",\"started\":\"2026-09-29T11:00:05Z\",\"stopped\":\"2026-09-29T11:01:10Z\",\"trigger_user\":{\"login\":\"alice\"}}";
}

pub const run_ok = run("40", "success", "main");
pub const run_failed = run("41", "failure", "main");
pub const run_running = run("42", "running", "feature");
pub const runs = "{\"total_count\":2,\"workflow_runs\":[" ++ run_ok ++ "," ++ run_failed ++ "]}";
pub const runs_feature = "{\"total_count\":1,\"workflow_runs\":[" ++ run_running ++ "]}";

pub const jobs =
    \\[{"id":500,"name":"build","status":"success","run_id":41},{"id":501,"name":"test","status":"failure","run_id":41}]
;

pub const user = "{\"login\":\"me\",\"full_name\":\"Me\"}";
pub const version = "{\"version\":\"16.0.5+gitea-1.22.0\"}";

pub const release =
    \\{"id":9,"tag_name":"v1.0.0","name":"One","body":"Notes.","draft":false,"prerelease":false,
    \\"html_url":"http://forge.test/owner/repo/releases/tag/v1.0.0","published_at":"2026-09-28T12:00:00Z","author":{"login":"alice"},
    \\"assets":[{"id":1,"name":"smith-linux.tar.gz","size":1536,"download_count":4,"browser_download_url":"BASE/attachments/1"},
    \\{"id":2,"name":"SHA256SUMS","size":64,"download_count":1,"browser_download_url":"BASE/attachments/2"}]}
;
