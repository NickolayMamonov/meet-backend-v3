def exact_keys($keys): (keys | sort) == ($keys | sort);
def proof($doc;$expectedPhase):
  ($doc[0]) as $proof |
  if ($proof | type == "object" and exact_keys([
        "bootstrapControlPresent","bootstrapMode","effectiveDefault",
        "imageDigest","imageId","introductionSha",
        "jarProductionSha256","jarPropertiesSha256","phase",
        "platform","schema","sourceProductionSha256",
        "sourcePropertiesSha256","sourceSha","strictAncestor",
        "treeId","version"
      ]) and
      .schema == "meet-backend/test-promotion-bootstrap-proof/v1" and
      (.imageDigest | test("^sha256:[0-9a-f]{64}$")) and
      (.imageId | test("^sha256:[0-9a-f]{64}$")) and
      (.sourceSha | test("^[0-9a-f]{40}$")) and
      (.treeId | test("^[0-9a-f]{40}$")) and
      (.version | test("^(0|[1-9][0-9]*)[.](0|[1-9][0-9]*)[.](0|[1-9][0-9]*)$")) and
      (.bootstrapMode == "declared-false" or
       .bootstrapMode == "legacy-not-applicable") and
      (.bootstrapControlPresent | type == "boolean") and
      (.effectiveDefault == false) and
      (.strictAncestor | type == "boolean") and
      .phase == $expectedPhase)
  then $proof else error("bootstrap proof is invalid") end;
def phase($p;$b;$proofSha;$expectedPhase):
  ($p[0]) as $x | proof($b;$expectedPhase) as $bootstrap |
  ($x.zeroStateProbe) as $probe |
  if (($x.image | split("@")[1]) != $bootstrap.imageDigest or
      $x.imageId != $bootstrap.imageId or
      $x.revision != $bootstrap.sourceSha or
      $x.version != $bootstrap.version)
  then error("phase is not bound to its bootstrap proof")
  else
    {
      imageDigest:($x.image | split("@")[1]), imageId:$x.imageId,
      sourceSha:$bootstrap.sourceSha, treeId:$bootstrap.treeId,
      version:$bootstrap.version,
      bootstrapProofSha256:$proofSha,
      configDigest:$x.runtimeConfigHash,
      runtimeDigest:$x.runtimeConfigHash,
      bootstrapMode:$bootstrap.bootstrapMode,
      bootstrapControlPresent:$bootstrap.bootstrapControlPresent,
      bootstrapDisabled:(if $bootstrap.bootstrapControlPresent then true else null end),
      healthy:$probe.runtime.containerHealthy,
      admissionMode:$probe.admission.mode,
      admissionStateSha256:$probe.admission.stateSha256,
      zeroStateProbe:$probe
    }
  end;
def identity($p;$bootstrap;$proofSha;$expectedPhase):
  ($p[0]) as $x |
  proof($bootstrap;$expectedPhase) as $verifiedBootstrap |
  ($x.zeroStateProbe.admission) as $admission |
  {
    stateMode:$admission.mode,
    stateSha256:$admission.stateSha256,
    imageReference:$x.image,
    imageId:$x.imageId,
    revision:$x.revision,
    version:$x.version,
    runtimeConfigHash:$x.runtimeConfigHash,
    bootstrapProofSha256:$proofSha,
    bootstrapMode:$verifiedBootstrap.bootstrapMode,
    bootstrapControlPresent:$verifiedBootstrap.bootstrapControlPresent,
    bootstrapDisabled:(if $verifiedBootstrap.bootstrapControlPresent then true else null end)
  };
{
  schema:"meet-backend/test-promotion-evidence-input/v2",
  source:{
    authoritySha:($authority[0].authoritySha),
    sourceSha:$source,treeId:$tree,version:$version
  },
  image:{
    image:$image,alias:$alias,admissionMode:$admissionMode,
    rootDigest:$root,platformDigest:$platform,platform:"linux/amd64",
    labels:{
      source:"https://github.com/NickolayMamonov/meet-backend-v3",
      revision:$source,version:$version
    },
    provenance:true,sbom:true,githubAttestation:true,
    referrerClosure:true,protectedStateEqual:true
  },
  deployment:{
    predecessor:phase($predecessor;$predecessorBootstrap;$predecessorProof;"predecessor"),
    candidate:phase($candidate;$candidateBootstrap;$candidateProof;"candidate"),
    rollback:{
      attempted:$rollbackAttempted,required:$rollbackRequired,
      predecessor:(if $rollbackRequired
        then identity($rollbackPredecessor;$rollbackPredecessorBootstrap;
          $rollbackPredecessorProof;"predecessor")
        else null end),
      restored:(if $rollbackRequired
        then identity($rollback;$rollbackBootstrap;$rollbackProof;"rollback")
        else null end),
      sameImageRedeploy:(if $rollbackRequired then false else true end),
      verified:$rollbackVerified
    },
    final:phase($final;$finalBootstrap;$finalProof;"final"),
    runtime:{
      topologyVerified:$final[0].zeroStateProbe.runtime.topologyVerified,
      hardeningVerified:$final[0].zeroStateProbe.runtime.hardeningVerified,
      volumesVerified:$final[0].zeroStateProbe.runtime.volumesVerified,
      volumes:(($final[0].zeroStateProbe.runtime.volumes +
        $final[0].zeroStateProbe.runtime.postgresVolumes) |
        map(.source) | sort),
      postgresWritablePrimary:
        $final[0].zeroStateProbe.runtime.postgresWritablePrimary,
      nonIdleApplicationTransactions:
        $final[0].zeroStateProbe.runtime.nonIdleApplicationTransactions,
      smtpIdleSamples:$final[0].zeroStateProbe.runtime.smtpIdleSamples
    },
    probes:{
      meetings200Json:($final[0].zeroStateProbe.http.meetingsStatus == 200 and
        $final[0].zeroStateProbe.http.meetingsJson == true and
        (if $stateMode == "empty-closed"
         then $final[0].zeroStateProbe.http.meetingsCount == 0
         else $final[0].zeroStateProbe.http.meetingsCount ==
           $admissionContract[0].populated.roots.meetings
         end)),
      actuator404:($final[0].zeroStateProbe.http.actuatorStatus == 404),
      httpRedirectHttps:$final[0].zeroStateProbe.http.httpRedirectHttps,
      adminMissing403:
        ($final[0].zeroStateProbe.http.adminMissingStatus == 403),
      adminWrong403:
        ($final[0].zeroStateProbe.http.adminWrongStatus == 403),
      adminKeyConfigured:
        $final[0].zeroStateProbe.http.adminKeyConfigured,
      adminAuthenticatedDisabled404:
        $final[0].zeroStateProbe.http.adminAuthenticatedDisabled404,
      adminBlankDisabled403:
        $final[0].zeroStateProbe.http.adminBlankDisabled403,
      assets:{
        count:$final[0].zeroStateProbe.http.assetsCount,
        verified:$final[0].zeroStateProbe.http.assetsVerified
      }
    }
  },
  control:{finalVerified:true,rollbackPolicySatisfied:true}
}
