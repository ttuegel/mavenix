let
  fetcher = { owner, repo, rev, sha256 }: builtins.fetchTarball {
    inherit sha256;
    url = "https://github.com/${owner}/${repo}/archive/${rev}.tar.gz";
  };
in {
  pkgs ? import (fetcher {
    owner   = "NixOS";
    repo    = "nixpkgs";
    rev     = "18.09";
    sha256  = "1ib96has10v5nr6bzf7v8kw7yzww8zanxgw2qi1ll1sbv6kj6zpd";
  }) {},
}:

let
  inherit (builtins) attrNames attrValues pathExists toJSON foldl' elemAt;
  inherit (pkgs) stdenv runCommand fetchurl makeWrapper maven writeText
    requireFile yq;
  inherit (pkgs.lib) concatLists concatStrings importJSON strings
    makeOverridable optionalAttrs optionalString;

  maven' = maven;
  settings' = writeText "settings.xml" ''
    <settings xmlns="http://maven.apache.org/SETTINGS/1.0.0"
      xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
      xsi:schemaLocation="http://maven.apache.org/SETTINGS/1.0.0
                          http://maven.apache.org/xsd/settings-1.0.0.xsd">
    </settings>
  '';

  mapmap = fs: ls: concatLists (map (v: map (f: f v) fs) ls);

  urlToScript = remoteList: dep:
    let
      inherit (dep) path sha1;
      authenticated = if (dep?authenticated) then dep.authenticated else false;

      fetch = if authenticated then (requireFile {
        inherit sha1;
        url = "${elemAt remoteList 0}/${path}";
      }) else (fetchurl {
        inherit sha1;
        urls = map (r: "${r}/${path}") remoteList;
      });
    in ''
      mkdir -p "$(dirname ${path})"
      ln -sfv "${fetch}" "${path}"
    '';

  metadataToScript = remote: meta:
    let
      inherit (meta) path content;
      name = "maven-metadata-${remote}.xml";
    in ''
      mkdir -p "${path}"
      ( cd "${path}"
        ln -sfv "${writeText "maven-metadata.xml" content}" "${name}"
        linkSnapshot "${name}" )
    '';

  drvToScript = drv: ''
    echo >&2 === building mavenix drvs: ${drv.name} ===
    props="${drv}/share/java/*.properties"
    for prop in $props; do getMavenPathFromProperties $prop; done
  '';

  transInfo = map (drv: importJSON "${drv}/share/mavenix/mavenix.lock");

  transDeps = tinfo: concatLists (map (info: info.deps) tinfo);
  transMetas = tinfo: concatLists (map (info: info.metas) tinfo);
  transRemotes = foldl' (acc: info: acc // info.remotes) {};

  mkRepo = {
    deps ? [],
    metas ? [],
    remotes ? {},
    drvs ? [],
    drvsInfo ? [],
  }: let
    deps' = deps ++ (transDeps drvsInfo);
    metas' = metas ++ (transMetas drvsInfo);
    remotes' = (transRemotes drvsInfo) // remotes;
    remoteList = attrValues remotes';
  in runCommand "mk-repo" {} ''
    set -e

    getMavenPath() {
      local version="$(sed -n 's|^version=||p' "$1")"
      local groupId="$(sed -n 's|^groupId=||p' "$1")"
      local artifactId="$(sed -n 's|^artifactId=||p' "$1")"
      echo "$(sed 's|\.|/|g' <<<"$groupId")/$artifactId/$version/$artifactId-$version"
    }

    linkSnapshot() {
      [ "$(${yq}/bin/xq '.metadata.versioning.snapshotVersions' < "$1")" == "null" ] \
        && return
      cat "$1" | ${yq}/bin/xq -r '
        .metadata as $o
          | [.metadata.versioning.snapshotVersions.snapshotVersion] | flatten | .[]
          | ((if .classifier? then ("-" + .classifier) else "" end) + "." + .extension) as $e
          | $o.artifactId + "-" + .value + $e + " " + $o.artifactId + "-" + $o.version + $e
      ' | xargs -L1 ln -sfv
    }

    getMavenPathFromProperties() {
      local path="$(getMavenPath "$1")"
      local bpath="$(dirname $path)"
      local basefilename="''${1%%.properties}"

      if test "$bpath"; then
        mkdir -p "$bpath"
        for fn in $basefilename-* $basefilename.{pom,jar}; do
          test ! -f $fn || ln -sfv "$fn" "$bpath"
        done
        ln -sfv "$basefilename.metadata.xml" "$bpath/maven-metadata-local.xml"
      fi
    }

    mkdir -p "$out"
    (cd $out
      ${concatStrings (map (urlToScript remoteList) deps')}
      ${concatStrings (mapmap
        (map metadataToScript (attrNames remotes')) metas')}
      ${concatStrings (map drvToScript drvs)}
    )
  '';

  cp-artifact = submod: ''
    find . -type f \
      -regex "${submod.path}/target/[^/]*\.\(jar\|war\)$" ! -name "*-sources.jar" \
      -exec cp -v {} $dir \;
  '';

  cp-pom = submod: ''
    cp -v ${submod.path}/pom.xml $dir/${submod.name}.pom
  '';

  mk-properties = submod: ''
    echo 'groupId=${submod.groupId}
    artifactId=${submod.artifactId}
    version=${submod.version}
    ' > $dir/${submod.name}.properties
  '';

  mk-maven-metadata = submod: ''
    echo '<metadata>
      <groupId>${submod.groupId}</groupId>
      <artifactId>${submod.artifactId}</artifactId>
      <version>${submod.version}</version>
    </metadata>
    ' > $dir/${submod.name}.metadata.xml
  '';

  buildMaven = makeOverridable ({
    src,
    infoFile,
    deps        ? [],
    drvs        ? [],
    settings    ? settings',
    maven       ? maven',
    buildInputs ? [],

    remotes     ? {},

    doCheck     ? true,
    debug       ? false,
    build       ? true,
    ...
  }@config':
    let
      dummy-info = { name = "update"; deps = []; metas = []; };

      config = config' // {
        buildInputs = buildInputs ++ [ maven' ];
      };
      info = if build then importJSON infoFile else dummy-info;
      remotes' = (optionalAttrs (info?remotes) info.remotes) // remotes;
      drvsInfo = transInfo drvs;

      emptyRepo = mkRepo {
        inherit drvs drvsInfo;
        remotes = remotes';
      };

      repo = mkRepo {
        inherit (info) deps metas;
        inherit drvs drvsInfo;
        remotes = remotes';
      };

      # Wrap mvn with settings to improve the nix-shell experience
      maven' = runCommand "mvn" {
        nativeBuildInputs = [ makeWrapper ];
      } ''
        mkdir -p $out/bin
        makeWrapper ${maven}/bin/mvn $out/bin/mvn --add-flags "--settings ${settings}"
      '';

      mvn = "${maven'}/bin/mvn --offline --batch-mode -Dmaven.repo.local=${repo} -nsu ";

      # Round-trip infoFile through the JSON parser to erase content-irrelevant
      # changes, such as whitespace.
      cleanInfoFile =
        writeText "mavenix.lock" (builtins.toJSON (importJSON infoFile));

    in
      stdenv.mkDerivation ({
        name = info.name;

        # Export as environment variable to make it possible to reuse default flags in other phases/hooks
        inherit mvn;

        postPhases = [ "mavenixDistPhase" ];

        checkPhase = optionalString build ''
          runHook preCheck

          $mvn test

          runHook postCheck
        '';

        buildPhase = optionalString build ''
          runHook preBuild

          $mvn --version
          $mvn package -DskipTests=true -Dmaven.test.skip=true

          runHook postBuild
        '';

        installPhase = optionalString build ''
          runHook preInstall

          dir="$out/share/java"
          mkdir -p $dir

          ${optionalString (info?submodules) (concatStrings (mapmap
            [ cp-artifact cp-pom mk-properties mk-maven-metadata ]
            info.submodules
          ))}

          runHook postInstall
        '';

        mavenixDistPhase = optionalString build ''
          mkdir -p $out/share/mavenix
          echo copying lock file
          cp -v ${cleanInfoFile} $out/share/mavenix/mavenix.lock
        '';
      } // (config // {
        deps = null;
        drvs = null;
        remotes = null;
        infoFile = null;
        mavenixMeta = toJSON {
          inherit deps emptyRepo settings;
          infoFile = toString infoFile;
          srcPath = toString src;
        };
      }))
  );
in rec {
  version = "1.0.0";
  name = "mavenix-${version}";
  updateInfo = f: infoFile:
    writeText "updated-lock" (
      toJSON ((x: x // f x) (importJSON infoFile))
    );
  inherit buildMaven pkgs;
}
