# Lists the boolean parameters that a command or job passes into a run step's
# environment, for check-bool-env-tests.sh.
#
# Input: {"file": "<path>", "doc": <the command or job YAML, as JSON>}
# Output: one tab-separated line per such parameter:
#   <file> <ENV_VAR> <parameter> <included script, or "(inline)">
(.doc.parameters // {}
  | to_entries
  | map(select(.value.type == "boolean") | .key)) as $bools
| .file as $file
| .doc.steps // []
| ..
| objects
| select(has("run"))
| .run
| objects
| (.command // "" | tostring
    | capture("include\\((?<s>scripts/[^)]+)\\)").s // "(inline)") as $script
| (.environment // {})
| to_entries[]
| select(.value | type == "string")
| (.value | capture("^\\s*<<\\s*parameters\\.(?<p>\\w+)\\s*>>\\s*$").p // null) as $p
| select($p != null and ($bools | index($p)) != null)
| [$file, .key, $p, $script]
| @tsv
