#!/usr/bin/env python3
"""
Thin CLI wrapper around Anthropic's computer_use_demo tools.
Called from the Node.js backend via `docker exec`.

Usage:
  python3 /relay_tool_runner.py screenshot
  python3 /relay_tool_runner.py computer '{"action":"left_click","coordinate":[512,400]}'
  python3 /relay_tool_runner.py bash '{"command":"ls -la"}'
  python3 /relay_tool_runner.py text_editor '{"command":"view","path":"/tmp/test.txt"}'
"""
import asyncio
import base64
import json
import sys
import os

# Ensure the computer_use_demo module is importable
sys.path.insert(0, "/home/computeruse")
os.environ.setdefault("WIDTH", "1024")
os.environ.setdefault("HEIGHT", "768")
os.environ.setdefault("DISPLAY_NUM", "1")


async def run_tool(tool_name: str, tool_input: dict) -> dict:
    """Run an Anthropic tool and return the result as JSON."""
    from computer_use_demo.tools.computer import ComputerTool20251124 as ComputerTool
    from computer_use_demo.tools.bash import BashTool20250124 as BashTool
    from computer_use_demo.tools.edit import EditTool20250728 as EditTool

    if tool_name == "screenshot":
        tool = ComputerTool()
        result = await tool.screenshot()
        return {"type": "screenshot", "base64": result.base64_image or ""}

    elif tool_name == "computer":
        tool = ComputerTool()
        # Keep coordinates as lists — Anthropic's validate_and_get_coordinates checks isinstance(coord, list)
        # (despite the type hint saying tuple)
        result = await tool(**tool_input)
        resp = {"type": "result"}
        if result.base64_image:
            resp["base64"] = result.base64_image
        if result.output:
            resp["output"] = result.output
        if result.error:
            resp["error"] = result.error
        return resp

    elif tool_name == "bash":
        tool = BashTool()
        result = await tool(**tool_input)
        resp = {"type": "result"}
        if result.output:
            resp["output"] = result.output
        if result.error:
            resp["error"] = result.error
        return resp

    elif tool_name == "text_editor":
        tool = EditTool()
        result = await tool(**tool_input)
        resp = {"type": "result"}
        if result.output:
            resp["output"] = result.output
        if result.error:
            resp["error"] = result.error
        return resp

    else:
        return {"type": "error", "error": f"Unknown tool: {tool_name}"}


def main():
    if len(sys.argv) < 2:
        print(json.dumps({"type": "error", "error": "Usage: relay_tool_runner.py <tool_name> [json_input]"}))
        sys.exit(1)

    tool_name = sys.argv[1]
    tool_input = {}

    if tool_name == "screenshot":
        tool_input = {"action": "screenshot"}
        tool_name = "computer"
    elif len(sys.argv) > 2:
        try:
            tool_input = json.loads(sys.argv[2])
        except json.JSONDecodeError as e:
            print(json.dumps({"type": "error", "error": f"Invalid JSON: {e}"}))
            sys.exit(1)

    result = asyncio.run(run_tool(tool_name, tool_input))
    print(json.dumps(result))


if __name__ == "__main__":
    main()
