#!/usr/bin/env python3
"""Launches trial builds as ECS Fargate tasks and watches them.

    ./runner.py run  --projects fixture,cpp-tutorial --modes local,cache,rbe --wave w1 [--workload clean,noop,leaf] [--repeat 2]
    ./runner.py wait <task-arn>...          # blocks until the tasks stop, prints exit codes
    ./runner.py logs <task-arn>             # prints the task's CloudWatch log
    ./runner.py list                        # running tasks

Reads cluster, task definition, subnets and security group from `terraform output -json`.
Uses the aws CLI (credentials from the environment) and nothing else.
"""
import argparse, itertools, json, os, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))


def sh(*args, **kw):
    return subprocess.run(args, check=True, capture_output=True, text=True, **kw).stdout


def tf_outputs():
    out = json.loads(sh("terraform", "output", "-json", cwd=HERE))
    return {k: v["value"] for k, v in out.items()}


def run(args):
    tf = tf_outputs()
    projects = json.load(open(os.path.join(HERE, "projects.json")))
    arns = []
    combos = list(itertools.product(args.projects.split(","), args.modes.split(","), range(args.repeat)))
    for name, mode, n in combos:
        p = projects[name]
        env = {
            "PROJECT": name, "REPO": p["repo"], "REF": p.get("ref", "HEAD"), "SUBDIR": p.get("subdir", ""),
            "TARGETS": p["targets"], "TEST_TARGETS": p.get("test_targets", p["targets"]),
            "MODE": mode, "WORKLOAD": args.workload, "WAVE": args.wave, "TAGS": f"run={n + 1}",
            "BAZEL_FLAGS": p.get("flags", ""),
        }
        if p.get("bazel_version"):
            env["USE_BAZEL_VERSION"] = p["bazel_version"]
        overrides = {"containerOverrides": [{"name": "builder", "environment": [{"name": k, "value": v} for k, v in env.items()]}]}
        net = {"awsvpcConfiguration": {"subnets": tf["builder_subnets"], "securityGroups": [tf["builder_sg"]], "assignPublicIp": "ENABLED"}}
        res = json.loads(sh(
            "aws", "ecs", "run-task", "--cluster", tf["ecs_cluster"], "--task-definition", tf["task_definition"],
            "--launch-type", "FARGATE", "--network-configuration", json.dumps(net), "--overrides", json.dumps(overrides),
            "--started-by", args.wave, "--tags", f"key=project,value={name}", f"key=mode,value={mode}", f"key=wave,value={args.wave}",
        ))
        for f in res.get("failures", []):
            print("FAILED to start", name, mode, f, file=sys.stderr)
        for t in res.get("tasks", []):
            arns.append(t["taskArn"])
            print(f"{name:14} {mode:6} run={n + 1}  {t['taskArn'].rsplit('/', 1)[-1]}")
        time.sleep(args.stagger)
    print("\n".join(arns), file=sys.stderr)
    return arns


def wait(arns, poll=30):
    tf = tf_outputs()
    pending = set(arns)
    while pending:
        res = json.loads(sh("aws", "ecs", "describe-tasks", "--cluster", tf["ecs_cluster"], "--tasks", *sorted(pending)))
        for t in res["tasks"]:
            if t["lastStatus"] == "STOPPED":
                pending.discard(t["taskArn"])
                c = t["containers"][0]
                print(f"{t['taskArn'].rsplit('/', 1)[-1]} stopped exit={c.get('exitCode')} reason={t.get('stoppedReason', '')}")
        if pending:
            print(f"{len(pending)} running…", file=sys.stderr)
            time.sleep(poll)


def logs(arn):
    tf = tf_outputs()
    task_id = arn.rsplit("/", 1)[-1]
    out = sh("aws", "logs", "get-log-events", "--log-group-name", f"/{tf['ecs_cluster'].removesuffix('-builders')}/builders",
             "--log-stream-name", f"build/builder/{task_id}", "--output", "json", "--query", "events[].message")
    print("\n".join(json.loads(out)))


def list_tasks():
    tf = tf_outputs()
    arns = json.loads(sh("aws", "ecs", "list-tasks", "--cluster", tf["ecs_cluster"]))["taskArns"]
    if not arns:
        print("no running tasks"); return
    res = json.loads(sh("aws", "ecs", "describe-tasks", "--cluster", tf["ecs_cluster"], "--tasks", *arns))
    for t in res["tasks"]:
        env = {e["name"]: e["value"] for e in t["overrides"]["containerOverrides"][0].get("environment", [])}
        print(f"{t['taskArn'].rsplit('/', 1)[-1]} {t['lastStatus']:10} {env.get('PROJECT', '?'):14} {env.get('MODE', '?'):6} {env.get('WAVE', '?')}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--projects", required=True); r.add_argument("--modes", default="local,cache,rbe")
    r.add_argument("--wave", required=True); r.add_argument("--workload", default="clean,noop,leaf,wide,buildfile,test")
    r.add_argument("--repeat", type=int, default=1); r.add_argument("--stagger", type=float, default=1.0)
    r.add_argument("--wait", action="store_true")
    w = sub.add_parser("wait"); w.add_argument("arns", nargs="+")
    l = sub.add_parser("logs"); l.add_argument("arn")
    sub.add_parser("list")
    a = ap.parse_args()
    if a.cmd == "run":
        arns = run(a)
        if a.wait: wait(arns)
    elif a.cmd == "wait": wait(a.arns)
    elif a.cmd == "logs": logs(a.arn)
    else: list_tasks()
