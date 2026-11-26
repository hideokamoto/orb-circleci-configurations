// Model of publishing a WordPress plugin to WordPress.org SVN with the orb
// command wporg_svn_deploy (src/scripts/wporg_svn_deploy.sh), run from
// several release pipelines whose deploy jobs may interleave, fail, lose the
// commit's response, and be rerun from failed or from start. Someone may
// also create a tag by hand.
//
// .circleci/scripts/check-quint-spec.sh checks two instances:
//   unguarded      - the command without its two version checks; the
//                    simulator must find a violation (this is why the checks
//                    exist, and it keeps the model able to fail)
//   as_implemented - the command as written; no violation may be found
//
// Keep GUARD_DOWNGRADE / GUARD_STALE_TRUNK in step with the script's
// served_version checks.
module wporg {
  // Versions are ordered integers (1 < 2 < 3 stands for 1.0.0 < 1.0.1 < ...).
  const VERSIONS: Set[int]
  // Deploy jobs, one per pipeline run, each publishing one version.
  const JOB_VERSION: str -> int
  // Someone (or another tool) can create tags/<v> without touching trunk.
  const ALLOW_MANUAL_TAG: bool
  // Skip (green) instead of moving trunk to a version older than trunk's
  // Stable tag.
  const GUARD_DOWNGRADE: bool
  // When tags/<v> exists but trunk's Stable tag is older than v, fail
  // instead of reporting "nothing to deploy".
  const GUARD_STALE_TRUNK: bool

  type Phase = Idle | CheckedOut | Done | Failed

  // Repository state. trunk = version named by trunk's Stable tag (0 = none).
  var trunk: int
  var tags: Set[int]
  var trunkRev: int   // revision of the last commit that changed trunk
  var rev: int
  // Job state
  var phase: str -> Phase
  var baseRev: str -> int
  var seenTrunk: str -> int
  var seenTags: str -> Set[int]
  // Bookkeeping for properties
  var reportedOk: Set[int]   // versions whose job finished green
  var highest: int           // highest version ever committed to trunk

  pure def max2(a: int, b: int): int = if (a > b) a else b

  action init = all {
    trunk' = 0, tags' = Set(), trunkRev' = 0, rev' = 0,
    phase' = JOB_VERSION.keys().mapBy(_ => Idle),
    baseRev' = JOB_VERSION.keys().mapBy(_ => 0),
    seenTrunk' = JOB_VERSION.keys().mapBy(_ => 0),
    seenTags' = JOB_VERSION.keys().mapBy(_ => Set()),
    reportedOk' = Set(), highest' = 0,
  }

  action unchangedRepo = all { trunk' = trunk, tags' = tags, trunkRev' = trunkRev, rev' = rev, highest' = highest }

  // svn checkout: the job sees the repository as of now.
  action checkout(j: str): bool = all {
    phase.get(j) == Idle,
    phase' = phase.set(j, CheckedOut),
    baseRev' = baseRev.set(j, rev),
    seenTrunk' = seenTrunk.set(j, trunk),
    seenTags' = seenTags.set(j, tags),
    reportedOk' = reportedOk,
    unchangedRepo,
  }

  action finish(j: str, p: Phase, ok: bool): bool = all {
    phase' = phase.set(j, p),
    reportedOk' = if (ok) reportedOk.union(Set(JOB_VERSION.get(j))) else reportedOk,
    baseRev' = baseRev, seenTrunk' = seenTrunk, seenTags' = seenTags,
  }

  // Everything after the checkout: the tag check, then either skip or commit.
  action decide(j: str): bool = {
    val v = JOB_VERSION.get(j)
    all {
      phase.get(j) == CheckedOut,
      if (seenTags.get(j).contains(v)) {
        // tags/<v> already exists
        if (GUARD_STALE_TRUNK and seenTrunk.get(j) < v)
          all { finish(j, Failed, false), unchangedRepo }
        else
          all { finish(j, Done, true), unchangedRepo }
      } else if (GUARD_DOWNGRADE and seenTrunk.get(j) > v) {
        // superseded by a newer version already on trunk: skip, green
        all { finish(j, Done, true), unchangedRepo }
      } else if (trunkRev > baseRev.get(j) or tags.contains(v)) {
        // svn commit: trunk changed since checkout (readme.txt always
        // differs between versions) or tags/<v> was added meanwhile
        all { finish(j, Failed, false), unchangedRepo }
      } else {
        // commit of trunk + tags/<v> succeeds; the client may still see an
        // error (lost response), which turns the job red
        all {
          trunk' = v, tags' = tags.union(Set(v)), rev' = rev + 1,
          trunkRev' = rev + 1, highest' = max2(highest, v),
          nondet lost = Set(true, false).oneOf()
          if (lost) finish(j, Failed, false) else finish(j, Done, true),
        }
      }
    }
  }

  // "Rerun workflow from failed" on a red deploy job.
  action rerun(j: str): bool = all {
    phase.get(j) == Failed,
    phase' = phase.set(j, Idle),
    baseRev' = baseRev, seenTrunk' = seenTrunk, seenTags' = seenTags,
    reportedOk' = reportedOk,
    unchangedRepo,
  }

  // "Rerun workflow from start" on a green deploy job.
  action rerunGreen(j: str): bool = all {
    phase.get(j) == Done,
    phase' = phase.set(j, Idle),
    baseRev' = baseRev, seenTrunk' = seenTrunk, seenTags' = seenTags,
    reportedOk' = reportedOk,
    unchangedRepo,
  }

  action manualTag(v: int): bool = all {
    ALLOW_MANUAL_TAG,
    not(tags.contains(v)),
    tags' = tags.union(Set(v)), rev' = rev + 1,
    trunk' = trunk, trunkRev' = trunkRev, highest' = highest,
    phase' = phase, baseRev' = baseRev, seenTrunk' = seenTrunk, seenTags' = seenTags,
    reportedOk' = reportedOk,
  }

  action step = any {
    nondet j = JOB_VERSION.keys().oneOf()
    any { checkout(j), decide(j), rerun(j), rerunGreen(j) },
    nondet v = VERSIONS.oneOf()
    manualTag(v),
  }

  // WordPress.org serves tags/<Stable tag>; it must exist.
  val stableTagExists = trunk == 0 or tags.contains(trunk)
  // Trunk never goes back to an older version than one already served.
  val noDowngrade = trunk == highest
  // A green deploy job means its version (or a newer one) is what is served.
  val greenMeansServed = reportedOk.forall(v => trunk >= v)

  val safety = stableTagExists and noDowngrade and greenMeansServed
}

// The command without its version checks.
module unguarded {
  import wporg(
    VERSIONS = Set(1, 2),
    JOB_VERSION = Map("p1" -> 1, "p2" -> 2),
    ALLOW_MANUAL_TAG = true,
    GUARD_DOWNGRADE = false,
    GUARD_STALE_TRUNK = false
  ).*
}

// The command as implemented.
module as_implemented {
  import wporg(
    VERSIONS = Set(1, 2, 3),
    JOB_VERSION = Map("p1" -> 1, "p2" -> 2, "p3" -> 3, "p2again" -> 2),
    ALLOW_MANUAL_TAG = true,
    GUARD_DOWNGRADE = true,
    GUARD_STALE_TRUNK = true
  ).*
}
