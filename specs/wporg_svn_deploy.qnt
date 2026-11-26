// Model of publishing a WordPress plugin to WordPress.org SVN with the orb
// command wporg_svn_deploy (src/scripts/wporg_svn_deploy.sh), run from the
// deploy jobs of several release pipelines. Jobs may run concurrently, fail
// on an out-of-date commit, lose the commit's response, and be rerun from
// failed or from start. Someone may also create a tag by hand.
//
// With SERIAL_GROUP, the deploy job is invoked with a CircleCI serial-group,
// as documented at
// https://circleci.com/docs/guides/orchestrate/controlling-serial-execution-across-your-organization/
//   - one job of the group runs at a time;
//   - "If a job from an older pipeline tries to run while a newer pipeline's
//     job is waiting or running", the older job is skipped.
// The documentation says nothing about rerunning an older pipeline's job
// after the newer pipeline's job has finished; the model lets it run.
//
// .circleci/scripts/check-quint-spec.sh checks three instances:
//   unguarded      - no serial-group, no version checks: must violate
//   serial_only    - serial-group, no version checks: must violate (a rerun
//                    of an older pipeline after the newer one finished)
//   as_implemented - serial-group and the version checks: must not violate
// The two that must violate keep the model able to fail.
//
// Keep GUARD_DOWNGRADE / GUARD_STALE_TRUNK in step with the script's
// served_version checks.
module wporg {
  // Versions are ordered integers (1 < 2 < 3 stands for 1.0.0 < 1.0.1 < ...).
  const VERSIONS: Set[int]
  // Deploy jobs, one per pipeline, mapped to the version the pipeline
  // released. semantic-release on main gives later pipelines higher
  // versions, so the version also orders the pipelines.
  const JOB_VERSION: str -> int
  // The deploy job is invoked with a serial-group.
  const SERIAL_GROUP: bool
  // Someone (or another tool) can create tags/<v> without touching trunk.
  const ALLOW_MANUAL_TAG: bool
  // Skip (green) instead of moving trunk to a version older than trunk's
  // Stable tag.
  const GUARD_DOWNGRADE: bool
  // When tags/<v> exists but trunk's Stable tag is older than v, fail
  // instead of reporting "nothing to deploy".
  const GUARD_STALE_TRUNK: bool

  // Pending: the pipeline has not reached the job yet. Queued: the job is
  // waiting to run. Skipped: serial-group skipped it.
  type Phase = Pending | Queued | CheckedOut | Done | Failed | Skipped

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

  def jobs = JOB_VERSION.keys()

  // A newer pipeline's job of the group is waiting or running.
  def newerWaitingOrRunning(j: str): bool =
    jobs.exists(k => JOB_VERSION.get(k) > JOB_VERSION.get(j) and
      (phase.get(k) == Queued or phase.get(k) == CheckedOut))

  def someoneRunning(j: str): bool =
    jobs.exists(k => k != j and phase.get(k) == CheckedOut)

  action init = all {
    trunk' = 0, tags' = Set(), trunkRev' = 0, rev' = 0,
    phase' = jobs.mapBy(_ => Pending),
    baseRev' = jobs.mapBy(_ => 0),
    seenTrunk' = jobs.mapBy(_ => 0),
    seenTags' = jobs.mapBy(_ => Set()),
    reportedOk' = Set(), highest' = 0,
  }

  action unchangedRepo = all { trunk' = trunk, tags' = tags, trunkRev' = trunkRev, rev' = rev, highest' = highest }
  action unchangedSeen = all { baseRev' = baseRev, seenTrunk' = seenTrunk, seenTags' = seenTags }

  action setPhase(j: str, p: Phase): bool = all {
    phase' = phase.set(j, p), reportedOk' = reportedOk, unchangedSeen, unchangedRepo,
  }

  // The pipeline reaches the deploy job (its upstream jobs finished).
  action arrive(j: str): bool = all { phase.get(j) == Pending, setPhase(j, Queued) }

  // serial-group skips an older pipeline's job while a newer one waits or runs.
  action skip(j: str): bool = all {
    SERIAL_GROUP, phase.get(j) == Queued, newerWaitingOrRunning(j),
    setPhase(j, Skipped),
  }

  // The job starts; svn checkout sees the repository as of now.
  action checkout(j: str): bool = all {
    phase.get(j) == Queued,
    not(SERIAL_GROUP) or (not(someoneRunning(j)) and not(newerWaitingOrRunning(j))),
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
    unchangedSeen,
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

  // "Rerun workflow from failed" / "from start": the job is queued again in
  // the same (older or newer) pipeline.
  action rerun(j: str): bool = all {
    Set(Failed, Done, Skipped).contains(phase.get(j)),
    setPhase(j, Queued),
  }

  action manualTag(v: int): bool = all {
    ALLOW_MANUAL_TAG,
    not(tags.contains(v)),
    tags' = tags.union(Set(v)), rev' = rev + 1,
    trunk' = trunk, trunkRev' = trunkRev, highest' = highest,
    phase' = phase, unchangedSeen, reportedOk' = reportedOk,
  }

  action step = any {
    nondet j = jobs.oneOf()
    any { arrive(j), skip(j), checkout(j), decide(j), rerun(j) },
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

// No serial-group, no version checks.
module unguarded {
  import wporg(
    VERSIONS = Set(1, 2),
    JOB_VERSION = Map("p1" -> 1, "p2" -> 2),
    SERIAL_GROUP = false,
    ALLOW_MANUAL_TAG = true,
    GUARD_DOWNGRADE = false,
    GUARD_STALE_TRUNK = false
  ).*
}

// serial-group, no version checks.
module serial_only {
  import wporg(
    VERSIONS = Set(1, 2),
    JOB_VERSION = Map("p1" -> 1, "p2" -> 2),
    SERIAL_GROUP = true,
    ALLOW_MANUAL_TAG = false,
    GUARD_DOWNGRADE = false,
    GUARD_STALE_TRUNK = false
  ).*
}

// serial-group and the command as implemented.
module as_implemented {
  import wporg(
    VERSIONS = Set(1, 2, 3),
    JOB_VERSION = Map("p1" -> 1, "p2" -> 2, "p3" -> 3),
    SERIAL_GROUP = true,
    ALLOW_MANUAL_TAG = true,
    GUARD_DOWNGRADE = true,
    GUARD_STALE_TRUNK = true
  ).*
}
