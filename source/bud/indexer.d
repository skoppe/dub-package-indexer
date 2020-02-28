module bud.indexer;

import std.stdio;
import std.json;
import std.traits;

// enum host = "https://dub.bytecraft.nl";
enum host = "http://code.dlang.org";

auto fetchJson(string url) {
  import std.net.curl : get;
  enum retries = 3;
  auto tries = 0;
  while (true) {
    try {
      return parseJSON(get(url));
    } catch (Exception e) {
      import std.stdio;
      writeln("retry ", url);
      if (tries >= retries)
        throw e;
    }
    tries++;
    import core.thread : Thread;
    import core.time : Duration, dur;
    Thread.sleep( dur!("msecs")( 2000 * tries ) );
  }
}

unittest {
  import unit_threaded;
  import std.range : front;
  fetchPackages("spasm").extractInfo.front.name.shouldEqual("spasm");
}

version (unittest) {
  auto testPackageMetas = [PackageMeta("wasm-sourcemaps", "0.0.4"), PackageMeta("wasm-reader", "0.0.6"), PackageMeta("spasm", "0.2.0-beta.5")];
}

struct PackageMeta {
  string name;
  string ver;
}

struct Package {
  string name;
  string ver;
  string content;
}

auto extractInfo(JSONValue packages) {
  import std.algorithm : map;
  return packages.array.map!((JSONValue j) => PackageMeta(j["name"].str, j["version"].str));
}

auto fetchInfo(PackageMeta p) {
  import std.format : format;
  import std.algorithm : map, filter;
  return fetchJson(host ~ "/api/packages/%s/info".format(p.name));
}

auto fetchPackages(string query) {
  return fetchJson(host ~ "/api/packages/search?q=" ~ query);
}

auto parseVersions(JSONValue info) {
  import std.algorithm : map;
  return info["versions"].array.map!(j => Package(j["name"].str, j["version"].str, j.toString()));
}

unittest {
  import unit_threaded;
  import std.algorithm : filter;
  auto packages = fetchInfo(PackageMeta("wasm-reader")).parseVersions();
  packages.filter!(p => p.ver == "0.0.1").shouldEqual([Package("wasm-reader", "0.0.1", "{\"authors\":[\"Sebastiaan Koppe\"],\"commitID\":\"0dc40326b7d4a3bf683a1b08532f70e0e1cb2b7c\",\"configurations\":[{\"name\":\"library\",\"targetType\":\"library\"},{\"dependencies\":{\"unit-threaded\":\">=0.0.0\"},\"excludedSourceFiles\":[\"source\\/app.d\"],\"mainSourceFile\":\"bin\\/ut.d\",\"name\":\"unittest\",\"preBuildCommands\":[\"dub run unit-threaded -c gen_ut_main -- -f bin\\/ut.d\"],\"targetType\":\"executable\"}],\"copyright\":\"Copyright © 2019, Sebastiaan Koppe\",\"date\":\"2019-01-12T15:18:59Z\",\"description\":\"A wasm binary reader\",\"license\":\"MIT\",\"name\":\"wasm-reader\",\"packageDescriptionFile\":\"dub.sdl\",\"readme\":\"\",\"version\":\"0.0.1\"}")]);
}

auto getPackageDir(P)(P p) if (hasMember!(P, "name")) {
  import std.algorithm : filter, joiner;
  import std.format : format;
  import std.conv : text;
  import std.range : only, take, retro;
  return only(p.name.take(2).text(), p.name.retro.take(2).text()).filter!(c => c.length > 0).joiner("/").text();
}

unittest {
  import unit_threaded;
  Package("wasm-sourcemaps","0.0.1").getPackageDir.shouldEqual("wa/sp");
  PackageMeta("wasm-sourcemaps","0.0.2").getPackageDir.shouldEqual("wa/sp");
}

struct Git {
  string sshKeyPath = "~/.ssh/id_rsa";
  auto clone(string repo, string path) {
    import std.process : executeShell, Config;
    import std.format : format;
    auto result = executeShell("GIT_SSH_COMMAND='ssh -i %s -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' git clone %s %s".format(sshKeyPath, repo, path));
    if (result.status != 0)
      throw new Exception("git clone failed", result.output);
    return GitRepo(sshKeyPath, repo, path);
  }
}

struct GitRepo {
  string sshKeyPath;
  string repo;
  string path;
  bool commitAll() {
    import std.process : executeShell, Config;
    import std.stdio;
    import std.algorithm : canFind;
    if (sshKeyPath.length == 0 || path.length == 0)
      return false;
    writeln("Committing");
    auto result = executeShell("git add .", null, Config.none, size_t.max, path);
    if (result.status != 0)
      throw new Exception("git add failed", result.output);
    executeShell("git config --local user.name dub-packages-indexer", null, Config.none, size_t.max, path);
    executeShell("git config --local user.email dub-packages-indexer@bytecraft.nl", null, Config.none, size_t.max, path);
    result = executeShell("git commit -am 'update index'", null, Config.none, size_t.max, path);
    if (result.status != 0)
      throw new Exception("git commit failed", result.output);
    return !result.output.canFind("nothing to commit");
  }
  void push() {
    import std.process : executeShell, Config;
    import std.stdio;
    import std.format : format;
    writeln("Pushing");
    auto result = executeShell("GIT_SSH_COMMAND='ssh -i %s -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' git push".format(sshKeyPath), null, Config.none, size_t.max, path);
    if (result.status != 0)
      throw new Exception("git push failed", result.output);
  }
}

struct Index {
  string path;
  GitRepo repo;
  private JSONValue index;
  void loadIndex(Git git, string repoUri) {
    import std.path : buildPath;
    import std.file : exists, readText;
    import std.process : executeShell, Config;
    import std.format : format;
    writeln("Syncing index");
    repo = git.clone(repoUri, path);
    auto filename = buildPath(path, "index.json");
    if (exists(filename))
      index = readText(filename).parseJSON();
  }
  void storeIndex() {
    import std.path : buildPath;
    import std.process : executeShell, Config;
    import std.algorithm : canFind;
    import std.file : write;
    auto filename = buildPath(path, "index.json");
    write(filename, index.toPrettyString());
    if (repo.commitAll())
      repo.push();
  }
  bool isAtLatestVersion(PackageMeta meta) {
    import std.path : buildPath;
    import std.file : exists;
    auto filename = buildPath(this.path,getPackageDir(meta), meta.name);
    if (!exists(filename))
      return false;
    if (index.isNull)
      return false;
    if (auto p = meta.name in index) {
      return (*p)["versions"].array[$-1].str == meta.ver;
    }
    return false;
  }
  private void storeResolution(JSONValue info) {
    import std.path : buildPath;
    auto p = PackageMeta(info["name"].str);
    import std.file : write, mkdirRecurse;
    import std.path : dirName;
    auto path = buildPath(this.path,getPackageDir(p));
    mkdirRecurse(path);
    auto filename = buildPath(path, p.name);
    write(filename, info.toPrettyString());
  }
  string loadRawPackage(string name) {
    import std.path : buildPath;
    import std.typecons : tuple;
    import std.file : exists, readText;
    auto filename = buildPath(this.path, getPackageDir(tuple!("name")(name)), name);
    if (!exists(filename)) {
      import std.stdio;
      version (unittest) {
        return `{"versions":[{"configurations":[{"name":"library"},{"dependencies":{},"name":"unittest"}],"dependencies":{},"name":"dummy","subPackages":[],"version":"0.2.0-beta.5"}]}`;
      } else
          throw new Exception("cannot find package "~ name);
    }
    return readText(filename);
  }
  JSONValue loadPackage(string name) {
    return loadRawPackage(name).parseJSON();
  }
  void store(PackageMeta p, JSONValue info) {
    import std.algorithm : each;
    auto indexData = info.minimizeForIndex();
    auto resData = info.minimizeForResolution(); 
    index[p.name] = indexData;
    storeResolution(resData);
  }
  string[] knownPackages() {
    return index.objectNoRef.keys;
  }
}

auto tempIndex() {
  import std.file : tempDir;
  import std.ascii : letters;
  import std.conv : to;
  import std.random : randomSample;
  import std.utf : byCodeUnit;
  import std.path : buildPath;
  auto id = letters.byCodeUnit.randomSample(20).to!string;
  return Index(buildPath(tempDir, id));
}

unittest {
  import std.path : buildPath;
  import std.file : readText, mkdirRecurse;
  import unit_threaded;
  import std.string : stripRight;
  auto index = tempIndex();
  scope(exit) {
    import std.file : rmdirRecurse;
    rmdirRecurse(index.path);
  }
  import std.stdio;
  writeln("temp index at ", index.path);
  mkdirRecurse(index.path);
  index.syncFolder("wasm");
  index.storeIndex();
  auto spasmLatestVersion = readText(buildPath(index.path, "sp/ms/spasm")).parseJSON()["versions"].array[$-1]["version"].str;
  index.isAtLatestVersion(PackageMeta("spasm",spasmLatestVersion)).shouldBeTrue;
}

auto syncFolder(ref Index index, string query = "") {
  import std.array : Appender;
  auto packages = fetchPackages(query).extractInfo;
  auto updated = Appender!(string[])();
  int errorCounter = 0;
  foreach(p; packages) {
    import std.stdio;
    if (index.isAtLatestVersion(p))
      continue;
    writeln("updating ", p.name);
    updated.put(p.name);
    JSONValue info;
    try {
      info = fetchInfo(p);
    } catch (Exception e) {
      errorCounter++;
      if (errorCounter > 10)
        throw e;
      continue;
    }
    index.store(p, info);
    import core.thread : Thread;
    import core.time : Duration, dur;
    Thread.sleep( dur!("msecs")( 400 ) );
  }
  return updated.data;
}

auto upload(ref Index index, string[] packages, string authkey, string authemail) {
  import requests;
  import std.range : chunks;
  import std.algorithm : map, each;
  import std.array : array;
  import std.format : format;
  import std.stdio;
  import std.conv :to;
  enum account = "f27b0f1e4e6f08c7796e12d22131df7c";
  enum namespace = "98d551d058b942509f32c8b20d65b93c";
  writefln("Uploading %s packages to cloudflare KV store", packages.length);
  packages.chunks(100).each!((chunk) {
      JSONValue data = chunk.map!((name){
          auto content = index.loadRawPackage(name);
          JSONValue entry;
          entry["key"] = "package-"~name;
          entry["value"] = content;
          return entry;
        }).array();
      auto rq = Request();
      rq.addHeaders(["X-Auth-Key": authkey]);
      rq.addHeaders(["X-Auth-Email": authemail]);
      string url = "https://api.cloudflare.com/client/v4/accounts/%s/storage/kv/namespaces/%s/bulk".format(account, namespace);
      auto rs = rq.put(url, data.toString(), "application/json");
      if (rs.code != 200) {
        throw new Exception("KV store failed "~rs.responseBody.to!string);
      }
    });
}

alias minimizeForIndex = minimize!minimizeVersionReference;
alias minimizeForResolution = minimize!minimizeVersion;

unittest {
  import unit_threaded;
  auto info = parseJSON(`{"categories": [],"dateAdded": "2018-03-24T01:49:55","documentationURL": "","id": "5ab5a0b38aa9923f251d843c","name": "_","owner": "56d00917748de384562e132d","repository": {"kind": "github","owner": "wilzbach","project": "d-underscore"},"versions": [{"authors": ["seb"],"commitID": "c3dfff1c665955b24ed5bfa60ab9617b2f19bd6d","copyright": "Copyright © 2018, seb","date": "2018-03-31T16:24:12Z","description": "TBA","license": "proprietary","name": "_","packageDescriptionFile": "dub.sdl","readme": "","targetType": "library","version": "~master"}]}`);
  info.minimizeForIndex.toString.shouldEqual(`{"categories":[],"commitID":"c3dfff1c665955b24ed5bfa60ab9617b2f19bd6d","dateAdded":"2018-03-24T01:49:55","description":"TBA","documentationURL":"","id":"5ab5a0b38aa9923f251d843c","name":"_","owner":"56d00917748de384562e132d","repository":{"kind":"github","owner":"wilzbach","project":"d-underscore"},"versions":["~master"]}`);
  info.minimizeForResolution.toString.shouldEqual(`{"categories":[],"commitID":"c3dfff1c665955b24ed5bfa60ab9617b2f19bd6d","dateAdded":"2018-03-24T01:49:55","description":"TBA","documentationURL":"","id":"5ab5a0b38aa9923f251d843c","name":"_","owner":"56d00917748de384562e132d","repository":{"kind":"github","owner":"wilzbach","project":"d-underscore"},"versions":[{"name":"_","version":"~master"}]}`);
}

JSONValue minimizeVersionReference(JSONValue info) {
  return info["version"];
}

JSONValue minimize(alias versionMinimizer)(JSONValue info) {
  import std.algorithm : map;
  import std.array : array;
  JSONValue clone;
  clone["categories"] = info["categories"];
  clone["dateAdded"] = info["dateAdded"];
  clone["documentationURL"] = info["documentationURL"];
  clone["id"] = info["id"];
  clone["name"] = info["name"];
  clone["owner"] = info["owner"];
  clone["repository"] = info["repository"];
  clone["versions"] = info["versions"].array.map!(versionMinimizer).array;
  JSONValue latest = info["versions"].array[$-1];
  clone["commitID"] = latest["commitID"];
  clone["description"] = latest["description"];
  return clone;
}

auto minimizeConfiguration(JSONValue config) {
  JSONValue min;
  min["name"] = config["name"];
  if ("dependencies" in config)
    min["dependencies"] = config["dependencies"];
  return min;
}

JSONValue minimizeVersion(JSONValue info) {
  if (info.type != JSONType.object)
    return info;
  import std.algorithm : map;
  import std.array : array;
  JSONValue min;
  import std.stdio;
  if (auto configs = "configurations" in info) {
    if ((*configs).type == JSONType.object) {
      JSONValue[] saneConfigs;
      foreach(string name, JSONValue value; (*configs).object) {
        JSONValue saneConfig;
        if (value.type != JSONType.object) {
          saneConfig["name"] = value;
        } else {
          saneConfig["name"] = name;
          if ("dependencies" in value)
            saneConfig["dependencies"] = value["dependencies"];
        }
        saneConfigs ~= saneConfig;
      }
      min["configurations"] = saneConfigs;
    } else
      min["configurations"] = info["configurations"].array.map!(minimizeConfiguration).array;
  }
  if (auto name = "name" in info)
    min["name"] = *name;
  if (auto ver = "version" in info)
    min["version"] = *ver;
  if ("dependencies" in info)
    min["dependencies"] = info["dependencies"];
  if ("subPackages" in info) {
    min["subPackages"] = info["subPackages"].array.map!(minimizeVersion).array;
  }
  return min;
}

unittest {
  import unit_threaded;
  parseJSON(`{"authors": ["Sebastiaan Koppe"],"commitID": "2cac40e64abde1e9b07a22131165893cf4b62300","configurations": [{"dflags": ["-betterC"],"name": "library","subConfigurations": {"stdx-allocator": "wasm"},"targetType": "library"},{"dependencies": {"unit-threaded": ">=0.0.0"},"importPaths": ["tests"],"name": "unittest","targetName": "ut","targetType": "library"}],"copyright": "Copyright © 2018, Sebastiaan Koppe","date": "2019-08-14T21:08:22Z","dependencies": {"optional": "~>0.16.0","stdx-allocator": ">=3.1.0-beta.2 <3.2.0-0"},"description": "A framework for writing single page applications","name": "spasm","subPackages": [{"copyright": "Copyright © 2018, Sebastiaan Koppe","dependencies": {"asdf": "~>0.3.0","sdlang-d": "~>0.10.4"},"license": "MIT","name": "bootstrap-webpack","path": "bootstrap-webpack"},{"authors": ["Sebastiaan Koppe"],"configurations": [{"dependencies": {"unit-threaded": ">=0.0.0"},"name": "unittest"}],"copyright": "Copyright © 2018, Sebastiaan Koppe","dependencies": {"asdf": "~>0.3.0"},"license": "MIT","name": "webidl"}],"version": "0.2.0-beta.5"}`).minimizeVersion().toString().shouldEqual(`{"configurations":[{"name":"library"},{"dependencies":{"unit-threaded":">=0.0.0"},"name":"unittest"}],"dependencies":{"optional":"~>0.16.0","stdx-allocator":">=3.1.0-beta.2 <3.2.0-0"},"name":"spasm","subPackages":[{"dependencies":{"asdf":"~>0.3.0","sdlang-d":"~>0.10.4"},"name":"bootstrap-webpack"},{"configurations":[{"dependencies":{"unit-threaded":">=0.0.0"},"name":"unittest"}],"dependencies":{"asdf":"~>0.3.0"},"name":"webidl"}],"version":"0.2.0-beta.5"}`);
}
