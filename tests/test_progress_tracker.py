#!/usr/bin/env python3
import json
import os
import shutil
import subprocess
import tempfile
import unittest

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
STATUS_BOARD_SCRIPT = os.path.join(REPO_ROOT, "scripts", "status_board.py")
UPDATE_PROGRESS_SCRIPT = os.path.join(REPO_ROOT, "scripts", "update_progress.py")


class TestProgressTracker(unittest.TestCase):
    def setUp(self):
        self.test_dir = tempfile.mkdtemp(prefix="herdr_status_test_")
        # Copy template into test_dir to ensure it gets ignored by status board
        template_src = os.path.join(REPO_ROOT, ".herdr", "status", "template.json")
        if os.path.isfile(template_src):
            shutil.copy(template_src, os.path.join(self.test_dir, "template.json"))

    def tearDown(self):
        shutil.rmtree(self.test_dir)

    def test_init_and_update_lifecycle(self):
        worker_id = "worker-test"

        # 1. Init
        cmd_init = [
            UPDATE_PROGRESS_SCRIPT,
            "--dir", self.test_dir,
            "--worker-id", worker_id,
            "--no-herdr",
            "init",
            "--task", "Implement core features",
            "--todos", "Subtask 1", "Subtask 2", "Subtask 3",
        ]
        res = subprocess.run(cmd_init, capture_output=True, text=True)
        self.assertEqual(res.returncode, 0, res.stderr)

        status_file = os.path.join(self.test_dir, f"{worker_id}.json")
        self.assertTrue(os.path.isfile(status_file))

        with open(status_file, "r") as f:
            data = json.load(f)
        self.assertEqual(data["worker_id"], worker_id)
        self.assertEqual(data["task"], "Implement core features")
        self.assertEqual(data["phase"], "planning")
        self.assertEqual(data["progress"], 0.0)
        self.assertEqual(len(data["todos"]), 3)

        # 2. Update todo 1 to done
        cmd_todo = [
            UPDATE_PROGRESS_SCRIPT,
            "--dir", self.test_dir,
            "--worker-id", worker_id,
            "--no-herdr",
            "todo",
            "--id", "1",
            "--status", "done",
        ]
        res = subprocess.run(cmd_todo, capture_output=True, text=True)
        self.assertEqual(res.returncode, 0, res.stderr)

        with open(status_file, "r") as f:
            data = json.load(f)
        self.assertEqual(data["todos"][0]["status"], "done")
        self.assertAlmostEqual(data["progress"], 0.33, places=2)
        self.assertEqual(data["progress_label"], "1/3 done")

        # 3. Add a new todo
        cmd_add = [
            UPDATE_PROGRESS_SCRIPT,
            "--dir", self.test_dir,
            "--worker-id", worker_id,
            "--no-herdr",
            "add-todo",
            "--text", "Subtask 4",
        ]
        res = subprocess.run(cmd_add, capture_output=True, text=True)
        self.assertEqual(res.returncode, 0, res.stderr)

        with open(status_file, "r") as f:
            data = json.load(f)
        self.assertEqual(len(data["todos"]), 4)
        self.assertAlmostEqual(data["progress"], 0.25, places=2)
        self.assertEqual(data["progress_label"], "1/4 done")

        # 4. Mark blocked
        cmd_block = [
            UPDATE_PROGRESS_SCRIPT,
            "--dir", self.test_dir,
            "--worker-id", worker_id,
            "--no-herdr",
            "blocked",
            "--reason", "Waiting on dependency",
        ]
        res = subprocess.run(cmd_block, capture_output=True, text=True)
        self.assertEqual(res.returncode, 0, res.stderr)

        with open(status_file, "r") as f:
            data = json.load(f)
        self.assertEqual(data["phase"], "blocked")
        self.assertIn("BLOCKED: Waiting on dependency", data["notes"])

        # 5. Mark done
        cmd_done = [
            UPDATE_PROGRESS_SCRIPT,
            "--dir", self.test_dir,
            "--worker-id", worker_id,
            "--no-herdr",
            "done",
            "--notes", "All verified",
        ]
        res = subprocess.run(cmd_done, capture_output=True, text=True)
        self.assertEqual(res.returncode, 0, res.stderr)

        with open(status_file, "r") as f:
            data = json.load(f)
        self.assertEqual(data["phase"], "done")
        self.assertEqual(data["progress"], 1.0)
        for t in data["todos"]:
            self.assertEqual(t["status"], "done")

    def test_status_board_rendering(self):
        # Empty dir should ignore template.json and show no active workers
        res = subprocess.run(
            [STATUS_BOARD_SCRIPT, "--dir", self.test_dir, "--once", "--no-color"],
            capture_output=True,
            text=True,
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("No active workers found", res.stdout)

        # Create a worker status file
        worker_file = os.path.join(self.test_dir, "worker-api.json")
        status_data = {
            "worker_id": "worker-api",
            "task": "Implement FastAPI user endpoints",
            "phase": "implementation",
            "progress": 0.65,
            "progress_label": "3/5 endpoints + tests",
            "todos": [
                {"id": "1", "text": "POST /users", "status": "done"},
                {"id": "2", "text": "GET /users/{id}", "status": "in_progress"},
                {"id": "3", "text": "Unit tests", "status": "todo"},
                {"id": "4", "text": "Integration tests", "status": "todo"},
            ],
            "last_update": "2026-09-03T00:12:00Z",
            "notes": "Auth middleware complete",
        }
        with open(worker_file, "w") as f:
            json.dump(status_data, f)

        res = subprocess.run(
            [STATUS_BOARD_SCRIPT, "--dir", self.test_dir, "--once", "--no-color"],
            capture_output=True,
            text=True,
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        out = res.stdout
        self.assertIn("worker-api", out)
        self.assertIn("[IMPLEMENTATION]", out)
        self.assertIn("3/5 endpoints + tests", out)
        self.assertIn("Implement FastAPI user endpoints", out)
        self.assertIn("✓ POST /users", out)
        self.assertIn("→ GET /users/{id}", out)
        self.assertIn("· Unit tests", out)
        self.assertIn("Auth middleware complete", out)

    def test_status_board_resilience_to_corrupt_json(self):
        # Write a corrupted json file
        bad_file = os.path.join(self.test_dir, "worker-broken.json")
        with open(bad_file, "w") as f:
            f.write("{ broken json ...")

        # Board should not crash
        res = subprocess.run(
            [STATUS_BOARD_SCRIPT, "--dir", self.test_dir, "--once", "--no-color"],
            capture_output=True,
            text=True,
        )
        self.assertEqual(res.returncode, 0, res.stderr)


if __name__ == "__main__":
    unittest.main()
