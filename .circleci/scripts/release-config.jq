# Builds the release pipeline's continuation config.
#
# Input (jq -s): [ <test-deploy.yml as JSON>, <release-workflow.yml as JSON> ]
# Output: test-deploy.yml with its workflows replaced by a single `release`
# workflow. It keeps every entry of the test-deploy workflow except the
# orb-tools/publish (dev orb) ones and appends the release job, which
# requires every kept entry. Release-only jobs come from release-workflow.yml.

def entry_job: if type == "string" then . else (keys[0]) end;
def entry_name:
  if type == "string" then .
  else (to_entries[0] | ((.value // {}) | .name) // .key)
  end;

.[0] as $td
| .[1] as $rw
| ($td.workflows["test-deploy"].jobs // error("test-deploy workflow has no jobs")) as $entries
| [ $entries[] | select(entry_job != "orb-tools/publish") ] as $kept
| if ($kept | length) == ($entries | length) then
    error("test-deploy workflow has no orb-tools/publish entry to replace")
  else . end
| ([ $kept[] | entry_name ]) as $names
| if ($names | index("orb-tools/pack")) == null then
    error("orb-tools/pack must stay in the release workflow (the release job unpacks its output)")
  else . end
| $td
| del(.workflows)
| .jobs = ((.jobs // {}) + $rw.jobs)
| .workflows = {
    "release": {
      "jobs": ($kept + [ { "release": ($rw.release_invocation + { "requires": $names }) } ])
    }
  }
