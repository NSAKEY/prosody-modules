# Introduction #

Implementation of [XEP-0313: Message Archive Management](http://xmpp.org/extensions/xep-0313.html).

# Details #

This module will archive all messages that match the simple rules setup by the
user, and allow the user to access this archive.

# Usage #

First copy the module to the prosody plugins directory.

Then add "mam" to your modules\_enabled list:
```
modules_enabled = {
	-- ...
	"mam",
	-- ...
}
storage = {
	-- This makes mod_mam use the sql2 storage backend (others will use internal)
	-- which at the time of this writing is the only one supporting stanza archives
	archive2 = "sql2";
}
```

See [Prosodys data storage documentation](https://prosody.im/doc/storage)
for more info on how to configure storage for different plugins.

# Configuration #

The MAM protocol includes a method of changing preferences regarding what
messages should be stored.  This allows users to enable or disable
archiving by default, and set rules for specific contacts. This module
will log no messages by default, for privacy concerns.  If you decide to
change this, you should inform your users.

```
	default_archive_policy = false -- other options are true or "roster";
```

This controls what messages are archived if the user hasn't set a
matching rule, or another personal default.

  * `false` means to store no messages. This is the default.
  * `"roster"` means to store messages to/from contacts in the users roster.
  * `true` means is to store all messages.

```
	max_archive_query_results = 20;
```

This is the largest number of messages that are allowed to be retrieved in one request.

# Compatibility #
| trunk | Works |
|:------|:------|
| 0.10 | Works |
| 0.9 | Does not work |
| 0.8 | Does not work |