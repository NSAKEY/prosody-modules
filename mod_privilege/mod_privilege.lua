-- XEP-0356 (Privileged Entity)
-- Copyright (C) 2015 Jérôme Poisson
--
-- This module is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--
-- Some parts come from mod_remote_roster (module by Waqas Hussain and Kim Alvefur, see https://code.google.com/p/prosody-modules/)

-- TODO: manage external <presence/> (for "roster" presence permission) when the account with the roster is offline

local jid = require("util/jid")
local set = require("util/set")
local st = require("util/stanza")
local roster_manager = require("core/rostermanager")
local user_manager = require("core/usermanager")
local hosts = prosody.hosts
local full_sessions = prosody.full_sessions;

local priv_session = module:shared("/*/privilege/session")

-- the folowing sets are used to forward presence stanza
if not priv_session.presence_man_ent  then
	priv_session.presence_man_ent = set.new()
end
local presence_man_ent = priv_session.presence_man_ent
if not priv_session.presence_roster then
	priv_session.presence_roster = set.new()
end
local presence_roster = priv_session.presence_roster

local _ALLOWED_ROSTER = set.new({'none', 'get', 'set', 'both'})
local _ROSTER_GET_PERM = set.new({'get', 'both'})
local _ROSTER_SET_PERM = set.new({'set', 'both'})
local _ALLOWED_MESSAGE = set.new({'none', 'outgoing'})
local _ALLOWED_PRESENCE = set.new({'none', 'managed_entity', 'roster'})
local _PRESENCE_MANAGED = set.new({'managed_entity', 'roster'})
local _TO_CHECK = {roster=_ALLOWED_ROSTER, message=_ALLOWED_MESSAGE, presence=_ALLOWED_PRESENCE}
local _PRIV_ENT_NS = 'urn:xmpp:privilege:1'
local _FORWARDED_NS = 'urn:xmpp:forward:0'


module:log("debug", "Loading privileged entity module ");


--> Permissions management <--

privileges = module:get_option("privileged_entities", {})

function advertise_perm(session, to_jid, perms)
	-- send <message/> stanza to advertise permissions
	-- as expained in § 4.2
	local message = st.message({to=to_jid})
					  :tag("privilege", {xmlns=_PRIV_ENT_NS})

	for _, perm in pairs({'roster', 'message', 'presence'}) do
		if perms[perm] then
			message:tag("perm", {access=perm, type=perms[perm]}):up()
		end
	end
	session.send(message)
end

function set_presence_perm_set(to_jid, perms)
	-- fill the global presence sets according to perms
	if _PRESENCE_MANAGED:contains(perms.presence) then
		presence_man_ent:add(to_jid)
	end
	if perms.presence == 'roster' then
		presence_roster:add(to_jid)
	end
end

function advertise_presences(session, to_jid, perms)
	-- send presence status for already conencted entities
	-- as explained in § 7.1
	-- people in roster are probed only for active sessions
	-- TODO: manage roster load for inactive sessions
	if not perms.presence then return; end
	local to_probe = {}
	for _, user_session in pairs(full_sessions) do
		if user_session.presence and _PRESENCE_MANAGED:contains(perms.presence) then
			local presence = st.clone(user_session.presence)
			presence.attr.to = to_jid
			module:log("debug", "sending current presence for "..tostring(user_session.full_jid))
			session.send(presence)
		end
		if perms.presence == "roster" then
			-- we reset the cache to avoid to miss a presence that just changed
			priv_session.last_presence = nil

			if user_session.roster then
				local bare_jid = jid.bare(user_session.full_jid)
				for entity, item in pairs(user_session.roster) do
					if entity~=false and entity~="pending" and (item.subscription=="both" or item.subscription=="to") then
						_, host = jid.split(entity)
						if not hosts[host] then -- we don't probe jid from hosts we manage
							-- using a table with entity as key avoid probing several time the same one
							to_probe[entity] = bare_jid
						end
					end
				end
			end
		end
	end

	-- now we probe peoples for "roster" presence permission
	for to_jid, from_jid in pairs(to_probe) do
		module:log("debug", "probing presence for %s (on behalf of %s)", tostring(to_jid), tostring(from_jid))
		local probe = st.presence({from=from_jid, to=to_jid, type="probe"})
		prosody.core_route_stanza(nil, probe)
	end
end

function on_auth(event)
	-- Check if entity is privileged according to configuration,
	-- and set session.privileges accordingly

	local session = event.session
	local bare_jid = jid.join(session.username, session.host)

	local ent_priv = privileges[bare_jid]
	if ent_priv ~= nil then
		module:log("debug", "Entity is privileged")
		for perm_type, allowed_values in pairs(_TO_CHECK) do
			local value = ent_priv[perm_type]
			if value ~= nil then
				if not allowed_values:contains(value) then
					module:log('warn', 'Invalid value for '..perm_type..' privilege: ['..value..']')
					module:log('warn', 'Setting '..perm_type..' privilege to none')
					ent_priv[perm_type] = nil
				end
				if value == 'none' then
					ent_priv[perm_type] = nil
				end
			end
		end
		-- extra checks for presence permission
		if ent_priv.permission == 'roster' and not _ROSTER_GET_PERM:contains(session.privileges.roster) then
			module:log("warn", "Can't allow roster presence privilege without roster \"get\" privilege")
			module:log("warn", "Setting presence permission to none")
			end_priv.permission = nil
		end

		if session.type == "component" then
			-- we send the message stanza only for component
			-- it will be sent at first <presence/> for other entities
			advertise_perm(session, bare_jid, ent_priv)
			set_presence_perm_set(bare_jid, ent_priv)
			advertise_presences(session, bare_jid, ent_priv)
		end
	end

	session.privileges = ent_priv
end

function on_presence(event)
	-- Permission are already checked at this point,
	-- we only advertise them to the entity
	local session, stanza = event.origin, event.stanza;
	if session.privileges then
		advertise_perm(session, session.full_jid, session.privileges)
		set_presence_perm_set(session.full_jid, session.privileges)
		advertise_presences(session, session.full_jid, session.privileges)
	end
end

module:hook('authentication-success', on_auth)
module:hook('component-authenticated', on_auth)
module:hook('presence/initial', on_presence)


--> roster permission <--

-- get
module:hook("iq-get/bare/jabber:iq:roster:query", function(event)
	local session, stanza = event.origin, event.stanza;
	if not stanza.attr.to then
		-- we don't want stanzas addressed to /self
		return;
	end

	if session.privileges and _ROSTER_GET_PERM:contains(session.privileges.roster) then
		module:log("debug", "Roster get from allowed privileged entity received")
		-- following code is adapted from mod_remote_roster
		local node, host = jid.split(stanza.attr.to);
		local roster = roster_manager.load_roster(node, host);

		local reply = st.reply(stanza):query("jabber:iq:roster");
		for entity_jid, item in pairs(roster) do
			if entity_jid and entity_jid ~= "pending" then
				local node, host = jid.split(entity_jid);
					reply:tag("item", {
						jid = entity_jid,
						subscription = item.subscription,
						ask = item.ask,
						name = item.name,
					});
					for group in pairs(item.groups) do
						reply:tag("group"):text(group):up();
					end
					reply:up(); -- move out from item
			end
		end
		-- end of code adapted from mod_remote_roster
		session.send(reply);
	else
	    module:log("warn", "Entity "..tostring(session.full_jid).." try to get roster without permission")
		session.send(st.error_reply(stanza, 'auth', 'forbidden'))
	end

	return true
end);

-- set
module:hook("iq-set/bare/jabber:iq:roster:query", function(event)
	local session, stanza = event.origin, event.stanza;
	if not stanza.attr.to then
		-- we don't want stanzas addressed to /self
		return;
	end

	if session.privileges and _ROSTER_SET_PERM:contains(session.privileges.roster) then
		module:log("debug", "Roster set from allowed privileged entity received")
		-- following code is adapted from mod_remote_roster
		local from_node, from_host = jid.split(stanza.attr.to);
		if not(user_manager.user_exists(from_node, from_host)) then return; end
		local roster = roster_manager.load_roster(from_node, from_host);
		if not(roster) then return; end

		local query = stanza.tags[1];
		for i_, item in ipairs(query.tags) do
			if item.name == "item"
				and item.attr.xmlns == "jabber:iq:roster" and item.attr.jid
					-- Protection against overwriting roster.pending, until we move it
				and item.attr.jid ~= "pending" then

				local item_jid = jid.prep(item.attr.jid);
				local node, host, resource = jid.split(item_jid);
				if not resource then
					if item_jid ~= stanza.attr.to then -- not self-item_jid
						if item.attr.subscription == "remove" then
							local r_item = roster[item_jid];
							if r_item then
								local to_bare = node and (node.."@"..host) or host; -- bare jid
								roster[item_jid] = nil;
								if roster_manager.save_roster(from_node, from_host, roster) then
									session.send(st.reply(stanza));
									roster_manager.roster_push(from_node, from_host, item_jid);
								else
									roster[item_jid] = item;
									session.send(st.error_reply(stanza, "wait", "internal-server-error", "Unable to save roster"));
								end
							else
								session.send(st.error_reply(stanza, "modify", "item-not-found"));
							end
						else
							local subscription = item.attr.subscription;
							if subscription ~= "both" and subscription ~= "to" and subscription ~= "from" and subscription ~= "none" then -- TODO error on invalid
								subscription = roster[item_jid] and roster[item_jid].subscription or "none";
							end
							local r_item = {name = item.attr.name, groups = {}};
							if r_item.name == "" then r_item.name = nil; end
							r_item.subscription = subscription;
							if subscription ~= "both" and subscription ~= "to" then
								r_item.ask = roster[item_jid] and roster[item_jid].ask;
							end
							for _, child in ipairs(item) do
								if child.name == "group" then
									local text = table.concat(child);
									if text and text ~= "" then
										r_item.groups[text] = true;
									end
								end
							end
							local olditem = roster[item_jid];
							roster[item_jid] = r_item;
							if roster_manager.save_roster(from_node, from_host, roster) then -- Ok, send success
								session.send(st.reply(stanza));
								-- and push change to all resources
								roster_manager.roster_push(from_node, from_host, item_jid);
							else -- Adding to roster failed
								roster[item_jid] = olditem;
								session.send(st.error_reply(stanza, "wait", "internal-server-error", "Unable to save roster"));
							end
						end
					else -- Trying to add self to roster
						session.send(st.error_reply(stanza, "cancel", "not-allowed"));
					end
				else -- Invalid JID added to roster
					module:log("warn", "resource: %s , host: %s", tostring(resource), tostring(host))
					session.send(st.error_reply(stanza, "modify", "bad-request")); -- FIXME what's the correct error?
				end
			else -- Roster set didn't include a single item, or its name wasn't  'item'
				session.send(st.error_reply(stanza, "modify", "bad-request"));
			end
		end -- for loop end
		-- end of code adapted from mod_remote_roster
	else -- The permission is not granted
	    module:log("warn", "Entity "..tostring(session.full_jid).." try to set roster without permission")
		session.send(st.error_reply(stanza, 'auth', 'forbidden'))
	end

	return true
end);


--> message permission <--

module:hook("message/host", function(event)
	local session, stanza = event.origin, event.stanza;
	local privilege_elt = stanza:get_child('privilege', _PRIV_ENT_NS)
	if privilege_elt==nil then return; end
	if session.privileges and session.privileges.message=="outgoing" then
		if #privilege_elt.tags==1 and privilege_elt.tags[1].name == "forwarded"
			and privilege_elt.tags[1].attr.xmlns==_FORWARDED_NS then
			local message_elt = privilege_elt.tags[1]:get_child('message', 'jabber:client')
			if message_elt ~= nil then
				local from_node, from_host, from_resource = jid.split(message_elt.attr.from)
				if from_resource == nil and hosts[from_host] then -- we only accept bare jids from one of the server hosts
					-- at this point everything should be alright, we can send the message
					prosody.core_route_stanza(nil, message_elt)
				else -- trying to send a message from a forbidden entity
	    			module:log("warn", "Entity "..tostring(session.full_jid).." try to send a message from "..tostring(message_elt.attr.from))
					session.send(st.error_reply(stanza, 'auth', 'forbidden'))
				end
			else -- incorrect message child
				session.send(st.error_reply(stanza, "modify", "bad-request", "invalid forwarded <message/> element"));
			end
		else -- incorrect forwarded child
			session.send(st.error_reply(stanza, "modify", "bad-request", "invalid <forwarded/> element"));
		end;
	else -- The permission is not granted
	    module:log("warn", "Entity "..tostring(session.full_jid).." try to send message without permission")
		session.send(st.error_reply(stanza, 'auth', 'forbidden'))
	end

	return true
end);


--> presence permission <--

function same_tags(tag1, tag2)
	-- check if two tags are equivalent

    if tag1.name ~= tag2.name then return false; end

	if #tag1 ~= #tag2 then return false; end

	for name, value in pairs(tag1.attr) do
		if tag2.attr[name] ~= value then return false; end
	end

	for i=1,#tag1 do
		if type(tag1[i]) == "string" then
			if tag1[i] ~= tag2[i] then return false; end
		else
			if not same_tags(tag1[i], tag2[i]) then return false; end
		end
	end

	return true
end

function same_presences(presence1, presence2)
	-- check that 2 <presence/> stanzas are equivalent (except for "to" attribute)
	-- /!\ if the id change but everything else is equivalent, this method return false
	-- this behaviour may change in the future
	if presence1.attr.from ~= presence2.attr.from or presence1.attr.id ~= presence2.attr.id
		or presence1.attr.type ~= presence2.attr.type then
		return false
	end

	if presence1.attr.id and presence1.attr.id == presence2.attr.id then return true; end

	if #presence1 ~= #presence2 then return false; end

	for i=1,#presence1 do
		if type(presence1[i]) == "string" then
			if presence1[i] ~= presence2[i] then return false; end
		else
			if not same_tags(presence1[i], presence2[i]) then return false; end
		end
	end

	return true
end

function forward_presence(presence, to_jid)
	presence_fwd = st.clone(presence)
	presence_fwd.attr.to = to_jid
	module:log("debug", "presence forwarded to "..to_jid..": "..tostring(presence_fwd))
	module:send(presence_fwd)
	-- cache used to avoid to send several times the same stanza
	priv_session.last_presence = presence
end

module:hook("presence/bare", function(event)
	if presence_man_ent:empty() and presence_roster:empty() then return; end

	local session, stanza = event.origin, event.stanza;
	if stanza.attr.type == nil or stanza.attr.type == "unavailable" then
		if not stanza.attr.to then
			for entity in presence_man_ent:items() do
				if stanza.attr.from ~= entity then forward_presence(stanza, entity); end
			end
		else -- directed presence
			-- we ignore directed presences from our own host, as we already have them
			_, from_host = jid.split(stanza.attr.from)
			if hosts[from_host] then return; end

			-- we don't send several time the same presence, as recommended in §7 #2
			if priv_session.last_presence and same_presences(priv_session.last_presence, stanza) then
			   return
			end

			for entity in presence_roster:items() do
				if stanza.attr.from ~= entity then forward_presence(stanza, entity); end
			end
		end
	end
end, 150)
