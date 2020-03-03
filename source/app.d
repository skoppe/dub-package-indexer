import bud.indexer;

import std.algorithm : canFind, countUntil;
import std.typecons : tuple;

bool shouldFetch(string[] args) {
  return args.canFind("--fetch");
}

bool shouldUpload(string[] args) {
  return args.canFind("--upload");
}

bool shouldSearchIndex(string[] args) {
  return args.canFind("--searchindex");
}

string parseAuthKey(string[] args) {
  return args.parseString("authkey");
}

string parseAuthEmail(string[] args) {
  return args.parseString("authemail");
}

string parseAzureSearchKey(string[] args) {
  return args.parseString("azuresearch");
}

string parseString(string[] args, string key) {
  import std.string : toUpper;
  import std.ascii : toUpper;
  import std.process : environment;
  auto idx = args.countUntil("--"~key);
  if (idx == -1 || idx+1 >= args.length) {
    auto value = environment.get("INDEXER_"~key.toUpper);
    if (value is null)
      throw new Exception("Requires --"~key~" [key] or env var INDEXER_"~key.toUpper);
    return value;
  }
  return args[idx+1];
}

auto parseCredentials(string[] args) {
  import std.file : exists, write, mkdirRecurse;
  import std.string : replace;
  if (exists("/.dockerenv") && !exists("/root/.ssh/id_rsa")) {
    auto sshkey = args.parseString("SSH").replace("\\n","\n");
    write("/root/.ssh/id_rsa", sshkey);
    import std.process : executeShell, Config;
    auto result = executeShell("chmod 600 /root/.ssh/id_rsa");
    if (result.status != 0)
      throw new Exception("Cannot set ssh permission "~result.output);
  }
  if (exists("creds.ini")) {
    import dini;
    auto ini = Ini.Parse("creds.ini");
    return tuple!("key","email","azureSearchKey")(ini["cloudflare"].getKey("key"),ini["cloudflare"].getKey("email"),ini["azure"].getKey("key"));
  }
  return tuple!("key","email","azureSearchKey")(args.parseAuthKey, args.parseAuthEmail, args.parseAzureSearchKey);
}

auto storeSSHKey(string value) {
  import std.string : replace;
  import std.process : executeShell, Config;
  import std.file : exists, write, mkdirRecurse, getcwd;
  import std.path : buildPath;
  auto sshkey = value.replace("\\n","\n");
  auto filename = buildPath(getcwd(), "dub-packages-indexer.tmp-key");
  write(filename, sshkey);
  auto result = executeShell("chmod 600 "~filename);
  if (result.status != 0)
    throw new Exception("Cannot set ssh key permission "~result.output);
  return filename;
}

auto removeSSHKey() {
  import std.path : buildPath;
  import std.file : exists, write, mkdirRecurse, getcwd, remove;
  auto filename = buildPath(getcwd(), "dub-packages-indexer.tmp-key");
  if (exists(filename))
    remove(filename);
}

auto getGit(string[] args) {
  import std.file : exists, write, mkdirRecurse;
  import std.string : replace;
  import std.process : environment;
  auto idx = args.countUntil("--ssh");
  if (idx == -1 || idx+1 >= args.length) {
    auto value = environment.get("INDEXER_SSH");
    if (value is null)
      return Git();
    return Git(storeSSHKey(value));
  }
  return Git(storeSSHKey(args[idx+1]));
}

void main(string[] args)
{
  bool fetch = args.shouldFetch();
  bool upload = args.shouldUpload();
  bool searchIndex = args.shouldSearchIndex();
  auto creds = args.parseCredentials();

  if (!fetch && !upload && !searchIndex) {
    throw new Exception("Requires either --fetch, --upload, --searchindex");
  }
  auto index = tempIndex();
  scope(exit) {
    removeSSHKey();
    import std.file : rmdirRecurse;
    rmdirRecurse(index.path);
  }
  index.loadIndex(args.getGit(), "git@github.com:skoppe/dub-packages-index.git");

  string[] updated;
  if (fetch) {
    try {
      updated = index.syncFolder();
    } catch (Exception e) {
      import std.stdio;
      writeln("Syncing aborted ", e.message, e.info);
    }
  } else
    updated = index.knownPackages();

  if (upload) {
    try {
      index.upload(updated, creds.key, creds.email);
    } catch (Exception e) {
      import std.stdio;
      writeln("Upload aborted ", e.message, e.info);
      return;
    }
  }

  if (searchIndex) {
    try {
      updated.azureSearch(creds.azureSearchKey);
    } catch (Exception e) {
      import std.stdio;
      writeln("Search index aborted ", e.message, e.info);
      return;
    }
  }

  index.storeIndex();
}
