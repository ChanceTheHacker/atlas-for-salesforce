/**
 * Reviewed metadata changes: back up first, review the proposed files, then deploy.
 *
 * 1. startBackup/backupStatus retrieve the components the agent wants to change and
 *    save them as a ZIP in Salesforce Files (the component downloads it right away).
 * 2. propose saves the agent's complete new files. Every file must belong to a
 *    component in the backup, so nothing is deployed without a backup.
 * 3. decide rejects, or deploys the backup overlaid with the proposed files.
 * 4. startRestore puts components back to an earlier version as a new change: it backs
 *    up the current version first, then deploys the older backup, so a restore can
 *    itself be undone. Atlas_Versions numbers each component's versions.
 */
public with sharing class Atlas_Changes {
    static final Integer MAX_COMPONENTS = 100;
    @TestVisible static Integer manifestChars = 131072;
    // Apex has 6 MB of memory per request; these keep a change well inside it.
    static final Integer MAX_FILE_CHARS = 1000000;
    static final Integer MAX_TOTAL_CHARS = 1500000;
    static final Integer MAX_RETURNED_CHARS = 1500000;
    static final Set<String> REVISABLE = new Set<String>{ 'Backed Up', 'Proposed', 'Rejected', 'Failed' };
    static final Set<String> CAN_BACK_UP = new Set<String>{ 'Backup Needed', 'Backed Up', 'Proposed', 'Rejected', 'Failed' };
    static final Set<String> TERMINAL_STATUSES = new Set<String>{ 'Deployed', 'Failed', 'Restored' };
    static final String MD_NS = 'http://soap.sforce.com/2006/04/metadata';
    static final String REMINDER = '\nREMINDER: each response must be at most 14,000 characters. Split larger replies into separate responses.';
    /** Longest list of errors or warnings one handoff repeats; the change keeps the rest. */
    static final Integer HANDOFF_ITEMS = 50;
    /**
     * Bundle types and their folders. A retrieve reports one entry per bundle file, such as
     * "atlasLib/history.js", but the component is the bundle: it deploys as a whole, and
     * a bundle deployed without some of its files loses them.
     */
    static final Map<String, String> BUNDLE_DIRS = new Map<String, String>{ 'LightningComponentBundle' => 'lwc', 'AuraDefinitionBundle' => 'aura' };
    static final String BUNDLE_NAME = '[A-Za-z][A-Za-z0-9_]{0,79}';
    /** Types whose source file deploys only together with its -meta.xml file. */
    static final Set<String> META_TYPES = new Set<String>{ 'ApexClass', 'ApexTrigger', 'ApexPage', 'ApexComponent' };
    /**
     * Directory and suffix of common types. A change of only these types needs no
     * describeMetadata callout, and every manifest stores only its requested types' paths.
     */
    static final Map<String, List<String>> KNOWN_PATHS = new Map<String, List<String>>{
        'ApexClass' => new List<String>{'classes', 'cls'}, 'ApexTrigger' => new List<String>{'triggers', 'trigger'},
        'ApexPage' => new List<String>{'pages', 'page'}, 'ApexComponent' => new List<String>{'components', 'component'},
        'LightningComponentBundle' => new List<String>{'lwc', ''}, 'AuraDefinitionBundle' => new List<String>{'aura', ''}
    };
    static final String FILE_LEVEL = ' was saved by an older Atlas release that listed each bundle file as its own component, so it cannot be deployed. '
        + 'Nothing was changed. Send atlas-backup with this change ID to back it up again, then send the proposal again.';

    public class Manifest {
        public String retrieveId;
        public List<Atlas_Api.Component> requested = new List<Atlas_Api.Component>();
        public List<Found> found = new List<Found>();
        public List<Atlas_Api.Component> missing = new List<Atlas_Api.Component>();
        /** Backup file path → keys ("Type:Name") of the components stored in it. */
        public Map<String, List<String>> files = new Map<String, List<String>>();
        /** Component keys included in the last deployment. */
        public List<String> deployed = new List<String>();
        public List<String> problems = new List<String>();
        /** What the backup holds that this change cannot touch: components or files Salesforce did not report unambiguously for the request. */
        public List<String> blocked = new List<String>();
        /** Metadata type → directory and suffix, obtained from this org. */
        public Map<String, List<String>> typePaths = new Map<String, List<String>>();
        /** Restore changes only: the change whose backup is deployed, its component keys and backup hash. */
        public Id restoreFrom;
        public List<String> restoreKeys = new List<String>();
        public String restoreSha;
        /** Restore changes only: its short label in version history, so restoring to it never nests labels. */
        public String versionLabel;
    }

    public class Found {
        public String type;
        public String name;
        public String file;
        public String modified;
        public String modifiedBy;
    }

    static String key(String type, String name) {
        return type + ':' + name;
    }

    public static Manifest manifest(Atlas_Change__c change) {
        if (String.isBlank(change.Components__c)) return new Manifest();
        // JSON.deserialize skips field initializers, so fill in anything the stored JSON lacks.
        Manifest m = (Manifest) JSON.deserialize(change.Components__c, Manifest.class);
        m.requested = m.requested ?? new List<Atlas_Api.Component>();
        m.found = m.found ?? new List<Found>();
        m.missing = m.missing ?? new List<Atlas_Api.Component>();
        m.files = m.files ?? new Map<String, List<String>>();
        m.deployed = m.deployed ?? new List<String>();
        m.problems = m.problems ?? new List<String>();
        m.blocked = m.blocked ?? new List<String>();
        m.restoreKeys = m.restoreKeys ?? new List<String>();
        m.typePaths = m.typePaths ?? new Map<String, List<String>>(KNOWN_PATHS);
        return m;
    }

    /** The component a key belongs to: "LightningComponentBundle:atlasLib/history.js" belongs to its bundle. */
    public static String logicalKey(String k) {
        if (k == null || !BUNDLE_DIRS.containsKey(k.substringBefore(':'))) return k;
        return k.substringBefore(':') + ':' + k.substringAfter(':').substringBefore('/');
    }

    /** True for a manifest saved before bundles were recognised: it lists bundle files as components. */
    static Boolean fileLevel(Manifest m) {
        for (Found f : m.found) if (BUNDLE_DIRS.containsKey(f.type) && (f.name ?? '').contains('/')) return true;
        for (List<String> keys : m.files.values()) for (String k : keys) if (logicalKey(k) != k) return true;
        for (String k : m.deployed) if (logicalKey(k) != k) return true;
        return false;
    }

    /** The bundle folder a path is in ("lwc/atlasLib"), or null if it is not inside one. */
    static String bundleFolder(String path) {
        String dir = path.substringBefore('/');
        if (!BUNDLE_DIRS.values().contains(dir) || !path.substringAfter('/').contains('/')) return null;
        return dir + '/' + path.substringAfter('/').substringBefore('/');
    }

    static Boolean inBundleDir(String path) {
        return BUNDLE_DIRS.values().contains(path.substringBefore('/'));
    }

    /**
     * A manifest saved before bundles were recognised, rebuilt by bundle from what it
     * recorded, or null when that cannot be done without guessing: every saved file must
     * belong to exactly one requested component, and everything it deployed or restores
     * must be one of them. Manifests that list no bundle files come back unchanged.
     */
    public static Manifest reconciled(Manifest m) {
        if (!fileLevel(m)) return m;
        Manifest r = (Manifest) JSON.deserialize(JSON.serialize(m), Manifest.class);
        List<Map<String, Object>> properties = new List<Map<String, Object>>();
        for (Found f : m.found) properties.add(new Map<String, Object>{ 'type' => f.type, 'fullName' => f.name, 'fileName' => f.file,
            'lastModifiedDate' => f.modified, 'lastModifiedByName' => f.modifiedBy });
        if (!index(r, properties, new List<String>(m.files.keySet())).isEmpty()) return null;
        Set<String> known = new Set<String>();
        for (Found f : r.found) known.add(key(f.type, f.name));
        for (Atlas_Api.Component c : r.missing) known.add(key(c.type, c.name));
        for (Found f : m.found) if (!known.contains(logicalKey(key(f.type, f.name)))) return null;
        r.deployed = logicalKeys(m.deployed);
        r.restoreKeys = logicalKeys(m.restoreKeys);
        if (!known.containsAll(r.deployed) || !known.containsAll(r.restoreKeys)) return null;
        return r;
    }

    static List<String> logicalKeys(List<String> keys) {
        Set<String> out = new Set<String>();
        for (String k : keys) out.add(logicalKey(k));
        return new List<String>(out);
    }

    /** The source manifest a restore deploys from, rebuilt by bundle if an older release saved it. */
    @TestVisible
    static Manifest restorableManifest(Atlas_Change__c source) {
        Manifest m = reconciled(manifest(source));
        if (m == null) throw new Atlas_Api.AtlasException('The backup of ' + source.Name + ' was saved by an older Atlas release that listed each bundle file '
            + 'as its own component, and its files cannot each be matched to one requested bundle. Nothing was restored. Restore from another change.');
        return m;
    }

    /**
     * Records what a finished retrieve holds: each requested component Salesforce returned,
     * once (a bundle once, not once per file), the requested ones it did not return, and the
     * component that owns each backed-up file. Anything Salesforce did not report
     * unambiguously for the request owns nothing, so no proposal can change it, and it is
     * neither found nor missing, so it cannot be declared as new either. Returns what was blocked.
     */
    @TestVisible
    static List<String> index(Manifest m, List<Map<String, Object>> properties, List<String> paths) {
        m.found.clear();
        m.missing.clear();
        m.files.clear();
        Set<String> wanted = new Set<String>();
        Set<String> wildcards = new Set<String>();
        for (Atlas_Api.Component c : m.requested) {
            if (c.name == '*') wildcards.add(c.type.toLowerCase());
            else wanted.add(key(c.type, c.name).toLowerCase());
        }
        Map<String, Found> byKey = new Map<String, Found>();
        Set<String> returned = new Set<String>();
        Set<String> ambiguous = new Set<String>();
        Set<String> blocked = new Set<String>();
        Set<String> explained = new Set<String>();
        for (Map<String, Object> p : properties ?? new List<Map<String, Object>>()) {
            String type = (String) p.get('type');
            String fullName = (String) p.get('fullName');
            String fileName = (String) p.get('fileName') ?? '';
            if (type == 'Package' || String.isBlank(type) || String.isBlank(fullName)) continue;
            String ns = (String) p.get('namespacePrefix');
            String name = fullName;
            String file = fileName;
            String dir = BUNDLE_DIRS.get(type);
            Boolean clear = String.isNotBlank(fileName);
            if (dir != null) {
                // The bundle is the first part of the reported name; its folder must agree.
                name = fullName.substringBefore('/');
                String folder = fileName.startsWith(dir + '/') ? fileName.substringAfter(dir + '/').substringBefore('/') : '';
                String local = String.isNotBlank(ns) && name.startsWith(ns + '__') ? name.substring(ns.length() + 2) : name;
                file = dir + '/' + folder;
                clear = Pattern.matches(BUNDLE_NAME, name) && folder.equals(local)
                    && fileName.equals(fullName.contains('/') ? file + '/' + fullName.substringAfter('/') : file);
                if (!clear && String.isNotBlank(folder)) ambiguous.add(key(type, folder).toLowerCase());
            }
            String lower = key(type, name).toLowerCase();
            // Own-namespace retrieves can return a local fullName for a qualified request.
            // Only accept the namespace actually reported for this retrieved component.
            String qualified = String.isNotBlank(ns) && !name.startsWith(ns + '__') ? key(type, ns + '__' + name).toLowerCase() : null;
            if (!wanted.contains(lower) && !(qualified != null && wanted.contains(qualified)) && !wildcards.contains(type.toLowerCase())) {
                blocked.add(type + ' ' + name + ' (not requested)');
                explained.add(file);
                continue;
            }
            returned.add(lower);
            if (qualified != null) returned.add(qualified);
            returned.add(type.toLowerCase() + ':*');
            Found f = byKey.get(lower);
            if (!clear || (f != null && !f.file.equals(file))) {
                ambiguous.add(lower);
                blocked.add(type + ' ' + name + ' (Salesforce reported ' + fileName + ' for ' + fullName + ')');
                explained.add(file);
                continue;
            }
            String modified = (String) p.get('lastModifiedDate');
            if (f == null) {
                f = new Found();
                f.type = type;
                f.name = name;
                f.file = file;
                byKey.put(lower, f);
            }
            if (f.modified == null || (modified != null && modified.compareTo(f.modified) > 0)) {
                f.modified = modified;
                f.modifiedBy = (String) p.get('lastModifiedByName');
            }
        }
        for (String k : byKey.keySet()) {
            Found f = byKey.get(k);
            if (!ambiguous.contains(k)) m.found.add(f);
            else blocked.add(f.type + ' ' + f.name + ' (Salesforce reported files in ' + f.file + ' that do not all belong to it)');
        }
        for (Atlas_Api.Component c : m.requested) {
            if (!returned.contains(key(c.type, c.name).toLowerCase())) m.missing.add(c);
        }
        // A bundle folder owns the files inside it; any other component owns its file, the
        // file's -meta.xml and anything in a folder of that name.
        Map<String, String> folders = new Map<String, String>();
        for (Found f : m.found) if (BUNDLE_DIRS.containsKey(f.type)) folders.put(f.file, key(f.type, f.name));
        Set<String> strays = new Set<String>();
        for (String path : paths) {
            if (path.endsWith('/') || path == 'package.xml') continue;
            List<String> owners = new List<String>();
            if (inBundleDir(path)) {
                String owner = folders.get(bundleFolder(path) ?? '');
                if (owner != null) owners.add(owner);
            } else {
                for (Found f : m.found) {
                    if (BUNDLE_DIRS.containsKey(f.type)) continue;
                    String k = key(f.type, f.name);
                    if ((path == f.file || path == f.file + '-meta.xml' || path.startsWith(f.file + '/')) && !owners.contains(k)) owners.add(k);
                }
            }
            String root = bundleFolder(path) ?? path.removeEnd('-meta.xml');
            if (owners.isEmpty() && !explained.contains(root)) strays.add(root);
            m.files.put(path, owners);
        }
        List<String> out = new List<String>(blocked);
        for (String stray : strays) out.add(stray + ' (in the backup, but no requested component owns it)');
        m.blocked = out;
        return out;
    }

    public static Atlas_Change__c load(Id changeId) {
        return [
            SELECT Id, Name, Status__c, Summary__c, Conversation__c, Components__c, Backup_File__c, Backup_Sha256__c, Proposal_File__c,
                Revision__c, Deploy_Id__c, Test_Level__c, Result__c, Decision_Note__c, Decided_By__c, Decided_By__r.Name, Decided_At__c, CreatedBy.Name, CreatedDate,
                Files_Removed__c
            FROM Atlas_Change__c WHERE Id = :changeId WITH USER_MODE
        ];
    }

    /** Restore changes deploy another change's backup; they are never backed up or revised themselves. */
    static void assertNotRestore(Atlas_Change__c change) {
        Atlas_Data.assertSourceChangesAllowed(change.Conversation__c);
        if (manifest(change).restoreFrom != null) {
            throw new Atlas_Api.AtlasException(change.Name + ' is a restore. Send atlas-backup without a change ID to start a new change.');
        }
    }

    static Blob fileData(Id versionId) {
        return [SELECT VersionData FROM ContentVersion WHERE Id = :versionId WITH USER_MODE].VersionData;
    }

    static String downloadUrl(Id versionId) {
        return versionId == null ? null : '/sfc/servlet.shepherd/version/download/' + versionId;
    }

    // ---------------------------------------------------------------- backup

    /** Starts the backup for a new change, or adds components to a change that has not been deployed. */
    @AuraEnabled
    public static String startBackup(Id conversationId, Id changeId, String summary, String componentsJson) {
        try {
            Schema.DescribeSObjectResult access = Atlas_Change__c.SObjectType.getDescribe();
            if (!access.isAccessible() || (changeId == null ? !access.isCreateable() : !access.isUpdateable()))
                throw new Atlas_Api.AtlasException('You do not have access to save Atlas changes.');
            Atlas_Data.assertSourceChangesAllowed(conversationId);
            if (conversationId != null) {
                Atlas_Conversation__c parent = [SELECT Id FROM Atlas_Conversation__c WHERE Id = :conversationId WITH USER_MODE];
                if (!canPost(conversationId)) throw new Atlas_Api.AtlasException('You can read this conversation but not add to it, so Atlas could not report the change back to the agent. Nothing was backed up.');
            }
            if (summary != null && summary.length() > 255) throw new Atlas_Api.AtlasException('Change summaries must be at most 255 characters. Nothing was truncated.');
            List<Atlas_Api.Component> wanted = Atlas_Api.components(JSON.deserializeUntyped(componentsJson), MAX_COMPONENTS);
            for (Atlas_Api.Component c : wanted) {
                if (BUNDLE_DIRS.containsKey(c.type) && c.name != '*' && !Pattern.matches(BUNDLE_NAME, c.name))
                    throw new Atlas_Api.AtlasException(c.type + ' ' + c.name + ' is not a bundle name. Back up a bundle by its name, such as atlasLib, not by one of its files.');
            }
            Atlas_Change__c change;
            if (changeId == null) {
                change = new Atlas_Change__c(Conversation__c = conversationId, Revision__c = 0);
            } else {
                change = load(changeId);
                assertNotRestore(change);
                if (!CAN_BACK_UP.contains(change.Status__c)) {
                    throw new Atlas_Api.AtlasException(change.Name + ' is ' + change.Status__c + '. Start a new change with a new backup.');
                }
                Set<String> keys = new Set<String>();
                for (Atlas_Api.Component c : wanted) keys.add(key(c.type, c.name));
                for (Atlas_Api.Component c : manifest(change).requested) {
                    if (!keys.contains(key(c.type, c.name))) wanted.add(c);
                }
                if (wanted.size() > MAX_COMPONENTS) throw new Atlas_Api.AtlasException('A change can hold at most ' + MAX_COMPONENTS + ' components.');
            }
            // Callouts must come before any database write in the same request.
            String asyncId = Atlas_Api.startRetrieve(wanted);
            Manifest m = changeId == null ? new Manifest() : manifest(change);
            m.requested = wanted;
            m.retrieveId = asyncId;
            m.typePaths = typePaths(wanted);
            if (changeId != null) {
                Atlas_Change__c locked = [SELECT Id FROM Atlas_Change__c WHERE Id = :changeId WITH USER_MODE FOR UPDATE];
                Atlas_Change__c current = load(changeId);
                if (current.Status__c != change.Status__c || current.Revision__c != change.Revision__c
                    || current.Components__c != change.Components__c || current.Proposal_File__c != change.Proposal_File__c) {
                    throw new Atlas_Api.AtlasException('This change changed while Salesforce was starting the backup. Reload it before trying again.');
                }
                change = current;
            }
            change.Components__c = manifestJson(m);
            if (String.isNotBlank(summary)) change.Summary__c = summary;
            change.Status__c = 'Backup Needed';
            upsert as user change;
            change = load(change.Id);
            return JSON.serialize(new Map<String, Object>{ 'change' => dto(change), 'asyncId' => asyncId });
        } catch (Exception e) {
            throw Atlas_Api.fail(e);
        }
    }

    /**
     * Directory and suffix of each requested type. Only types outside KNOWN_PATHS need
     * describeMetadata, and only requested types are kept: the full describe is about
     * 17,000 characters and used to fill most of every change's manifest.
     */
    @TestVisible
    static Map<String, List<String>> typePaths(List<Atlas_Api.Component> wanted) {
        Map<String, List<String>> paths = new Map<String, List<String>>();
        Set<String> unknown = new Set<String>();
        for (Atlas_Api.Component c : wanted) {
            if (KNOWN_PATHS.containsKey(c.type)) paths.put(c.type, KNOWN_PATHS.get(c.type));
            else unknown.add(c.type);
        }
        if (unknown.isEmpty()) return paths;
        Atlas_Api.SoapResult types = Atlas_Api.metadata('describeMetadata', '<asOfVersion>' + Atlas_Api.VERSION + '</asOfVersion>');
        for (Dom.XmlNode type : Atlas_Api.children(types.node.getChildElement('result', MD_NS), 'metadataObjects')) {
            String name = Atlas_Api.text(type, 'xmlName');
            if (unknown.contains(name)) paths.put(name, new List<String>{ Atlas_Api.text(type, 'directoryName'), Atlas_Api.text(type, 'suffix') ?? '' });
        }
        return paths;
    }

    /** When the retrieve is done, saves the ZIP and returns the current files. */
    @AuraEnabled
    public static String backupStatus(Id changeId, String asyncId) {
        try {
            Atlas_Change__c change = load(changeId);
            assertNotRestore(change);
            if (String.isBlank(asyncId) || manifest(change).retrieveId != asyncId) {
                throw new Atlas_Api.AtlasException('This backup request is no longer current. Start the backup again.');
            }
            Atlas_Api.Retrieved result = Atlas_Api.checkRetrieve(asyncId);
            if (!result.done) return JSON.serialize(new Map<String, Object>{ 'done' => false, 'status' => result.status });
            if (result.zip == null) throw new Atlas_Api.AtlasException('The backup failed: ' + (result.error ?? result.status));

            Atlas_Change__c locked = [SELECT Id FROM Atlas_Change__c WHERE Id = :changeId WITH USER_MODE FOR UPDATE];
            change = load(changeId);
            if (manifest(change).retrieveId != asyncId) {
                throw new Atlas_Api.AtlasException('This backup request changed while Salesforce was retrieving it. Start the backup again.');
            }
            // A second poll after the backup was saved must not save it again.
            if (change.Status__c != 'Backup Needed') {
                return JSON.serialize(new Map<String, Object>{
                    'done' => true, 'change' => dto(change), 'files' => Atlas_Api.unzip(result.zip, MAX_RETURNED_CHARS)
                });
            }
            saveBackup(change, manifest(change), result, 'Before ' + change.Name + (String.isBlank(change.Summary__c) ? '' : ': ' + change.Summary__c));
            change.Status__c = 'Backed Up';
            change.Proposal_File__c = null;
            change.Revision__c = (change.Revision__c ?? 0) + 1;
            change.Decision_Note__c = null;
            change.Result__c = null;
            update as user change;
            return JSON.serialize(new Map<String, Object>{
                'done' => true, 'change' => dto(load(changeId)), 'files' => Atlas_Api.unzip(result.zip, MAX_RETURNED_CHARS)
            });
        } catch (Exception e) {
            throw Atlas_Api.fail(e);
        }
    }

    /**
     * Saves a finished retrieve as the change's backup ZIP and records what it found.
     * The caller sets the status and saves the change.
     */
    static void saveBackup(Atlas_Change__c change, Manifest m, Atlas_Api.Retrieved result, String description) {
        m.problems = new List<String>(result.problems ?? new List<String>());
        List<String> paths = new List<String>();
        for (Compression.ZipEntry entry : new Compression.ZipReader(result.zip).getEntries()) paths.add(entry.getName());
        index(m, result.properties, paths);
        // A failed deployment from an older release may have listed bundle files; record their bundles.
        m.deployed = logicalKeys(m.deployed);
        String recorded = manifestJson(m);

        ContentVersion version = new ContentVersion(
            Title = (change.Name + ' backup' + (String.isBlank(change.Summary__c) ? '' : ': ' + change.Summary__c)).abbreviate(255),
            PathOnClient = change.Name + '-backup.zip', VersionData = result.zip, Description = description.abbreviate(1000)
        );
        if (change.Backup_File__c == null) {
            version.FirstPublishLocationId = change.Id;
        } else {
            version.ContentDocumentId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :change.Backup_File__c WITH USER_MODE].ContentDocumentId;
            version.ReasonForChange = 'More components added to the backup';
        }
        insert as user version;
        change.Backup_File__c = version.Id;
        change.Backup_Sha256__c = Atlas_Api.sha256(result.zip);
        change.Components__c = recorded;
        change.Files_Removed__c = null;
    }

    // ---------------------------------------------------------------- proposal

    /** Saves the agent's proposed files for review. */
    @AuraEnabled
    public static String propose(Id changeId, String proposalJson) {
        try {
            Atlas_Change__c locked = [SELECT Id FROM Atlas_Change__c WHERE Id = :changeId WITH USER_MODE FOR UPDATE];
            Atlas_Change__c change = load(changeId);
            assertNotRestore(change);
            if (!REVISABLE.contains(change.Status__c)) {
                throw new Atlas_Api.AtlasException(change.Name + ' is ' + change.Status__c
                    + '. A proposal needs a backed-up change; send atlas-backup for a new change first.');
            }
            if (change.Backup_File__c == null) {
                throw new Atlas_Api.AtlasException('The backup of ' + change.Name + ' was removed to free storage. Send atlas-backup for a new change first.');
            }
            Map<String, Object> proposal = (Map<String, Object>) JSON.deserializeUntyped(proposalJson);
            if (proposal.get('summary') instanceof String && ((String)proposal.get('summary')).length() > 255)
                throw new Atlas_Api.AtlasException('Change summaries must be at most 255 characters. Nothing was truncated.');
            applyEdits(change, proposal);
            Manifest m = manifest(change);
            Map<String, List<String>> owners = owners(m, proposal);
            preflight(m, touched(owners), owners);
            Decimal revision = (change.Revision__c ?? 0) + 1;
            ContentVersion version = new ContentVersion(
                Title = 'Atlas proposal ' + change.Name + ' revision ' + revision, PathOnClient = change.Name + '-proposal-' + revision + '.json',
                VersionData = Blob.valueOf(JSON.serialize(proposal))
            );
            if (change.Proposal_File__c == null) {
                version.FirstPublishLocationId = change.Id;
            } else {
                version.ContentDocumentId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :change.Proposal_File__c WITH USER_MODE].ContentDocumentId;
            }
            insert as user version;
            change.Proposal_File__c = version.Id;
            change.Revision__c = revision;
            change.Status__c = 'Proposed';
            change.Decision_Note__c = null;
            change.Result__c = null;
            if (proposal.get('summary') instanceof String) change.Summary__c = (String) proposal.get('summary');
            update as user change;
            return getChange(changeId);
        } catch (Exception e) {
            throw Atlas_Api.fail(e);
        }
    }

    /**
     * Turns a file's "edits" (exact find and replace, applied in order) into its complete
     * new content, starting from the backed-up file. Small edits keep agent replies short.
     */
    static void applyEdits(Atlas_Change__c change, Map<String, Object> proposal) {
        if (!(proposal.get('files') instanceof List<Object>)) return;
        Compression.ZipReader reader = null;
        for (Object item : (List<Object>) proposal.get('files')) {
            if (!(item instanceof Map<String, Object>) || ((Map<String, Object>) item).get('edits') == null) continue;
            Map<String, Object> file = (Map<String, Object>) item;
            String path = String.valueOf(file.get('path'));
            if (file.get('content') != null) throw new Atlas_Api.AtlasException(path + ' has both "content" and "edits". Send one of them.');
            if (!(file.get('edits') instanceof List<Object>) || ((List<Object>) file.get('edits')).isEmpty()) {
                throw new Atlas_Api.AtlasException(path + ': "edits" must be a list of {"find": ..., "replace": ...}.');
            }
            reader = reader ?? new Compression.ZipReader(fileData(change.Backup_File__c));
            Compression.ZipEntry entry = reader.getEntry(path);
            if (entry == null) throw new Atlas_Api.AtlasException(path + ' is not in the backup, so it cannot be edited. Send its complete "content".');
            String text = reader.extract(entry).toString();
            Integer n = 0;
            for (Object raw : (List<Object>) file.get('edits')) {
                n++;
                Map<String, Object> edit = raw instanceof Map<String, Object> ? (Map<String, Object>) raw : new Map<String, Object>();
                String find = edit.get('find') instanceof String ? (String) edit.get('find') : '';
                String replacement = edit.get('replace') instanceof String ? (String) edit.get('replace') : null;
                String label = 'Edit ' + n + ' in ' + path;
                if (find == '' || replacement == null) throw new Atlas_Api.AtlasException(label + ' needs "find" and "replace" text.');
                if (!text.contains(find) && text.contains('\r\n')) {
                    find = find.replace('\r\n', '\n').replace('\n', '\r\n');
                    replacement = replacement.replace('\r\n', '\n').replace('\n', '\r\n');
                }
                Integer at = text.indexOf(find);
                if (at < 0) throw new Atlas_Api.AtlasException(label + ': the "find" text is not in the file. Copy it exactly from the backup, including spaces and line breaks.');
                if (text.indexOf(find, at + 1) >= 0) throw new Atlas_Api.AtlasException(label + ': the "find" text appears more than once. Include more surrounding lines so it matches once.');
                text = text.substring(0, at) + replacement + text.substring(at + find.length());
            }
            file.put('content', text);
            file.remove('edits');
        }
    }

    /**
     * Checks every proposed file and returns the component key each one deploys.
     * Files must come from the backup, live inside a backed-up bundle, or declare a
     * backed-up component that does not exist yet. A bundle file always belongs to its
     * bundle, so the rest of the bundle comes from the backup and is never resent.
     */
    static Map<String, List<String>> owners(Manifest m, Map<String, Object> proposal) {
        if (fileLevel(m)) throw new Atlas_Api.AtlasException('This backup' + FILE_LEVEL);
        if (!(proposal.get('files') instanceof List<Object>)) throw new Atlas_Api.AtlasException('The change has no "files" list.');
        List<Object> files = (List<Object>) proposal.get('files');
        if (files.isEmpty() || files.size() > 200) throw new Atlas_Api.AtlasException('Send 1 to 200 files.');
        Map<String, String> requested = new Map<String, String>();
        for (Atlas_Api.Component c : m.requested) requested.put(key(c.type, c.name).toLowerCase(), key(c.type, c.name));
        Map<String, String> bundles = new Map<String, String>();
        Map<String, String> folders = new Map<String, String>();
        for (Found f : m.found) {
            if (BUNDLE_DIRS.containsKey(f.type)) folders.put(f.file, key(f.type, f.name));
            else bundles.put(f.file + '/', key(f.type, f.name));
        }

        Map<String, List<String>> result = new Map<String, List<String>>();
        Set<String> seen = new Set<String>();
        Integer total = 0;
        for (Object item : files) {
            Map<String, Object> file = item instanceof Map<String, Object> ? (Map<String, Object>) item : new Map<String, Object>();
            String path = file.get('path') instanceof String ? (String) file.get('path') : '';
            String content = file.get('content') instanceof String ? (String) file.get('content') : null;
            if (!Pattern.matches('[A-Za-z0-9_][A-Za-z0-9_ .()\\-/]{0,250}', path) || path.contains('..') || path.contains('//') || path.endsWith('/')
                || ('/' + path + '/').contains('/./') || path == 'package.xml' || (inBundleDir(path) && bundleFolder(path) == null)) {
                throw new Atlas_Api.AtlasException('Invalid file path "' + path + '". Use Metadata API paths such as classes/MyClass.cls or lwc/myBundle/myBundle.js.');
            }
            if (content == null) throw new Atlas_Api.AtlasException(path + ' has no "content". Send the complete file.');
            if (content.length() > MAX_FILE_CHARS) throw new Atlas_Api.AtlasException(path + ' is larger than ' + MAX_FILE_CHARS + ' characters.');
            total += content.length();
            // Salesforce treats paths that differ only in letter case as the same file.
            if (!seen.add(path.toLowerCase())) throw new Atlas_Api.AtlasException(path + ' appears twice.');

            List<String> keys = new List<String>();
            if (inBundleDir(path)) {
                // Only a bundle Salesforce reported for this change owns its folder.
                String owner = folders.get(bundleFolder(path));
                if (owner != null) keys.add(owner);
            } else {
                keys.addAll(m.files.get(path) ?? new List<String>());
                if (keys.isEmpty()) {
                    for (String prefix : bundles.keySet()) {
                        if (path.startsWith(prefix)) keys.add(bundles.get(prefix));
                    }
                }
            }
            if (keys.isEmpty() && file.get('type') instanceof String && file.get('name') instanceof String) {
                String declared = requested.get(key((String) file.get('type'), (String) file.get('name')).toLowerCase());
                if (declared != null && newComponentPath(m, declared, path)) keys.add(declared);
            }
            if (keys.isEmpty()) {
                throw new Atlas_Api.AtlasException(path + ' is not part of the backup. Every changed or new component must be backed up first: '
                    + 'send atlas-backup with this change ID and the extra component, then resend. For a new component, add "type" and "name" to the file and include it in the backup request.');
            }
            result.put(path, keys);
        }
        if (total > MAX_TOTAL_CHARS) throw new Atlas_Api.AtlasException('The proposed files exceed ' + MAX_TOTAL_CHARS + ' characters in total. Split the change.');
        return result;
    }

    static Boolean newComponentPath(Manifest m, String component, String path) {
        Boolean missing = false;
        for (Atlas_Api.Component c : m.missing) missing = missing || key(c.type, c.name) == component;
        if (!missing) return false;
        String type = component.substringBefore(':');
        String name = component.substringAfter(':');
        if (BUNDLE_DIRS.containsKey(type)) {
            String folder = BUNDLE_DIRS.get(type) + '/' + name;
            if (!Pattern.matches(BUNDLE_NAME, name) || !folder.equals(bundleFolder(path))) return false;
            // A folder the backup already holds is not new, even if Salesforce did not report it.
            for (String saved : m.files.keySet()) if (folder.equalsIgnoreCase(bundleFolder(saved))) return false;
            for (Found f : m.found) if (folder.equalsIgnoreCase(f.file)) return false;
            return true;
        }
        List<String> location = m.typePaths.get(type);
        if (location == null || String.isBlank(location[0]) || name.contains('*') || name.contains('..')) return false;
        String root = location[0] + '/' + name;
        if (String.isBlank(location[1])) return false;
        String file = root + '.' + location[1];
        return path == file || path == file + '-meta.xml';
    }

    static Set<String> touched(Map<String, List<String>> owners) {
        Set<String> out = new Set<String>();
        for (List<String> keys : owners.values()) out.addAll(keys);
        return out;
    }

    static Map<String, Blob> overlay(Map<String, Object> proposal) {
        Map<String, Blob> out = new Map<String, Blob>();
        for (Object item : (List<Object>) proposal.get('files')) {
            Map<String, Object> file = (Map<String, Object>) item;
            out.put((String) file.get('path'), Blob.valueOf((String) file.get('content')));
        }
        return out;
    }

    /** The files and package.xml members one deployment sends. */
    @TestVisible
    class Contents {
        @TestVisible List<String> paths = new List<String>();
        @TestVisible Set<String> members = new Set<String>();
    }

    /**
     * Every backed-up file of each touched component (a bundle needs all of its files),
     * replaced or extended by the proposed files, and the components package.xml lists.
     */
    static Contents contents(Manifest m, Set<String> touched, Set<String> proposed) {
        Contents c = new Contents();
        Set<String> paths = new Set<String>(proposed);
        c.members.addAll(touched);
        for (String path : m.files.keySet()) {
            Boolean include = false;
            for (String k : m.files.get(path)) include = include || touched.contains(k);
            if (!include) continue;
            paths.add(path);
            // A file shared by several components (fields in one object file) deploys them all.
            c.members.addAll(m.files.get(path));
        }
        c.paths.addAll(paths);
        c.paths.sort();
        return c;
    }

    /**
     * Checks a deployment before anything is sent: every component is a real component of
     * this backup (bundles by bundle name, never a file), every file belongs to one of them,
     * each bundle is complete and has its entry and metadata files, and no file appears
     * twice. Throws with every problem found, so a malformed package never reaches Salesforce.
     */
    @TestVisible
    static Contents preflight(Manifest m, Set<String> touched, Map<String, List<String>> proposed) {
        List<String> problems = new List<String>();
        if (fileLevel(m)) problems.add('The backup' + FILE_LEVEL);
        Map<String, Found> found = new Map<String, Found>();
        for (Found f : m.found) found.put(key(f.type, f.name), f);
        Set<String> missing = new Set<String>();
        for (Atlas_Api.Component c : m.missing) missing.add(key(c.type, c.name));
        Contents c = contents(m, touched, proposed.keySet());
        Map<String, List<String>> byMember = new Map<String, List<String>>();
        for (String k : c.members) {
            String type = k.substringBefore(':');
            String name = k.substringAfter(':');
            byMember.put(k, new List<String>());
            if (!Pattern.matches('[A-Za-z]{2,80}', type) || String.isBlank(name) || name.contains('*')
                || (BUNDLE_DIRS.containsKey(type) && !Pattern.matches(BUNDLE_NAME, name)))
                problems.add(k.replace(':', ' ') + ' is not a valid component name' + (name.contains('/') ? ': bundles deploy by bundle name, not by file.' : '.'));
            else if (!found.containsKey(k) && !missing.contains(k)) problems.add(k.replace(':', ' ') + ' is not in the backup of this change.');
        }
        Set<String> seen = new Set<String>();
        for (String path : c.paths) {
            if (!seen.add(path.toLowerCase())) problems.add(path + ' appears more than once (letter case aside).');
            if (path == 'package.xml' || path.contains('..') || path.startsWith('/')) problems.add(path + ' is not a valid file path.');
            List<String> owners = proposed.containsKey(path) ? proposed.get(path) : m.files.get(path);
            if (owners == null || owners.isEmpty()) {
                problems.add(path + ' belongs to no component of this change.');
                continue;
            }
            for (String k : owners) {
                if (!c.members.contains(k)) problems.add(path + ' belongs to ' + k.replace(':', ' ') + ', which this deployment does not list.');
                else byMember.get(k).add(path);
                String type = k.substringBefore(':');
                String folder = BUNDLE_DIRS.containsKey(type) ? (found.containsKey(k) ? found.get(k).file : BUNDLE_DIRS.get(type) + '/' + k.substringAfter(':')) : null;
                if (folder != null && (owners.size() != 1 || !folder.equals(bundleFolder(path))))
                    problems.add(path + ' is not inside the folder of ' + k.replace(':', ' ') + ' (' + folder + ').');
            }
        }
        for (String k : c.members) {
            List<String> paths = byMember.get(k);
            if (paths.isEmpty()) {
                problems.add(k.replace(':', ' ') + ' has no files in this deployment.');
                continue;
            }
            String type = k.substringBefore(':');
            List<String> location = m.typePaths?.get(type);
            if (META_TYPES.contains(type) && (found.containsKey(k) || (location != null && String.isNotBlank(location[1])))) {
                // Apex code deploys only with its -meta.xml file.
                String file = found.containsKey(k) ? found.get(k).file : location[0] + '/' + k.substringAfter(':') + '.' + location[1];
                if (!paths.contains(file) || !paths.contains(file + '-meta.xml'))
                    problems.add(k.replace(':', ' ') + ' needs both ' + file + ' and ' + file.substringAfterLast('/') + '-meta.xml.');
            }
            if (!BUNDLE_DIRS.containsKey(type) || !Pattern.matches(BUNDLE_NAME, k.substringAfter(':'))) continue;
            String folder = found.containsKey(k) ? found.get(k).file : BUNDLE_DIRS.get(type) + '/' + k.substringAfter(':');
            String base = folder + '/' + folder.substringAfterLast('/');
            Set<String> have = new Set<String>(paths);
            Boolean entry = false;
            if (type == 'LightningComponentBundle') {
                for (String ext : new List<String>{ '.js', '.ts', '.html', '.css' }) entry = entry || have.contains(base + ext);
                if (!have.contains(base + '.js-meta.xml')) problems.add(folder + ' has no ' + base.substringAfterLast('/') + '.js-meta.xml.');
                if (!entry) problems.add(folder + ' has no ' + base.substringAfterLast('/') + '.js, .html or .css file.');
            } else {
                for (String ext : new List<String>{ '.cmp', '.app', '.evt', '.intf', '.tokens' }) entry = entry || (have.contains(base + ext) && have.contains(base + ext + '-meta.xml'));
                if (!entry) problems.add(folder + ' has no ' + base.substringAfterLast('/') + '.cmp, .app, .evt, .intf or .tokens file with its -meta.xml.');
            }
        }
        if (!problems.isEmpty()) {
            List<String> lines = new List<String>{ 'The deployment package failed its checks, so nothing was sent to Salesforce:' };
            addItems(lines, problems);
            throw new Atlas_Api.AtlasException(String.join(lines, '\n'));
        }
        return c;
    }

    /** Reads the built archive back: exactly the checked files once each, and a package.xml listing exactly the checked components. */
    @TestVisible
    static void verifyArchive(Blob zip, Contents expected) {
        List<String> problems = new List<String>();
        Compression.ZipReader reader = new Compression.ZipReader(zip);
        List<String> paths = new List<String>();
        Compression.ZipEntry manifestEntry;
        for (Compression.ZipEntry entry : reader.getEntries()) {
            if (entry.getName() == 'package.xml') {
                if (manifestEntry != null) problems.add('package.xml appears more than once.');
                manifestEntry = entry;
            } else paths.add(entry.getName());
        }
        paths.sort();
        if (!String.join(paths, '\n').equals(String.join(expected.paths, '\n'))) problems.add('The archive holds ' + String.join(paths, ', ') + ' instead of ' + String.join(expected.paths, ', ') + '.');
        Set<String> members = new Set<String>();
        String version;
        if (manifestEntry == null) problems.add('The archive has no package.xml.');
        else {
            Dom.Document doc = new Dom.Document();
            doc.load(reader.extract(manifestEntry).toString());
            for (Dom.XmlNode types : doc.getRootElement().getChildElements()) {
                if (types.getName() == 'version') version = types.getText();
                if (types.getName() != 'types') continue;
                String type = types.getChildElement('name', MD_NS)?.getText();
                for (Dom.XmlNode member : types.getChildElements()) if (member.getName() == 'members') members.add(type + ':' + member.getText());
            }
            if (!members.equals(expected.members))
                problems.add('package.xml lists ' + String.join(new List<String>(members), ', ') + ' instead of ' + String.join(new List<String>(expected.members), ', ') + '.');
            if (version != Atlas_Api.VERSION) problems.add('package.xml is for API version ' + version + ', not ' + Atlas_Api.VERSION + '.');
        }
        if (!problems.isEmpty()) {
            List<String> lines = new List<String>{ 'The built deployment package does not match its checks, so nothing was sent to Salesforce:' };
            addItems(lines, problems);
            throw new Atlas_Api.AtlasException(String.join(lines, '\n'));
        }
    }

    @AuraEnabled
    public static String getChange(Id changeId) {
        try {
            Atlas_Change__c change = load(changeId);
            Map<String, Object> out = dto(change);
            out.put('activatesFlow', false);
            Map<String, Object> storedResult = pending(change);
            if (storedResult?.get('fileId') != null) out.put('result', fullResult(change));
            if (change.Proposal_File__c != null) {
                Map<String, Object> proposal = (Map<String, Object>) JSON.deserializeUntyped(fileData(change.Proposal_File__c).toString());
                out.put('proposal', proposal);
                out.put('activatesFlow', activates(proposal));
                Set<String> paths = new Set<String>();
                for (Object item : (List<Object>) proposal.get('files')) paths.add((String) ((Map<String, Object>) item).get('path'));
                Map<String, String> before = new Map<String, String>();
                if (change.Backup_File__c != null) {
                    Compression.ZipReader reader = new Compression.ZipReader(fileData(change.Backup_File__c));
                    for (String path : paths) {
                        Compression.ZipEntry entry = reader.getEntry(path);
                        if (entry == null) continue;
                        try {
                            before.put(path, reader.extract(entry).toString());
                        } catch (StringException binary) {
                            before.put(path, '[binary file]');
                        }
                    }
                }
                out.put('before', before);
            }
            return JSON.serialize(out);
        } catch (Exception e) {
            throw Atlas_Api.fail(e);
        }
    }

    // ---------------------------------------------------------------- decision and deployment

    /**
     * Rejects, or approves and deploys, a reviewed revision. testLevel is Default,
     * RunSpecifiedTests (the agent's tests), RunLocalTests or NoTestRun.
     */
    @AuraEnabled
    public static String decide(Id changeId, Integer revision, Boolean approve, String note, String testLevel) {
        return decideInternal(changeId, revision, approve, note, testLevel, false);
    }

    @AuraEnabled
    public static String decideConfirmed(Id changeId, Integer revision, Boolean approve, String note, String testLevel, Boolean activationConfirmed) {
        return decideInternal(changeId, revision, approve, note, testLevel, activationConfirmed == true);
    }

    static Boolean activates(Map<String,Object> proposal) {
        for (Object item : (List<Object>) proposal.get('files')) {
            Map<String,Object> file = (Map<String,Object>)item;
            String path = (String)file.get('path');
            if (!path.startsWith('flows/') && !path.startsWith('flowDefinitions/')) continue;
            // Apex DOM text extraction omits CDATA. Accumulate stream text events;
            // the reader resolves character references, while CDATA stays literal.
            XmlStreamReader reader = new XmlStreamReader((String)file.get('content'));
            Integer depth = 0;
            Boolean activation = false;
            String activationElement;
            String value = '';
            while (reader.hasNext()) {
                XmlTag event = reader.getEventType();
                if (event == XmlTag.START_ELEMENT) {
                    depth++;
                    String name = reader.getLocalName();
                    if (depth == 2 && MD_NS.equals(reader.getNamespace()) && (name.equals('status') || name.equals('activeVersionNumber'))) {
                        activationElement = name;
                        value = '';
                    } else if (activationElement != null) {
                        throw new Atlas_Api.AtlasException('Flow activation fields must contain text only.');
                    }
                } else if (activationElement != null && depth == 2
                    && (event == XmlTag.CHARACTERS || event == XmlTag.CDATA || event == XmlTag.SPACE || event == XmlTag.ENTITY_REFERENCE)) {
                    value += reader.getText();
                } else if (event == XmlTag.END_ELEMENT) {
                    if (depth == 2 && activationElement != null) {
                        // Padding around the value still activates in Salesforce, so it still asks for confirmation.
                        if (activationElement == 'status') activation = activation || value.trim() == 'Active';
                        // Anything but a plain zero counts as activating, so an odd value asks for confirmation instead of failing.
                        else if (String.isNotBlank(value)) activation = activation || !value.trim().containsOnly('0');
                        activationElement = null;
                    }
                    depth--;
                }
                reader.next();
            }
            if (activation) return true;
        }
        return false;
    }

    static String decideInternal(Id changeId, Integer revision, Boolean approve, String note, String testLevel, Boolean activationConfirmed) {
        try {
            // Reserve the reviewed revision in this transaction. The worker makes callouts
            // after commit; a second approval can no longer race past this check.
            Atlas_Change__c locked = [SELECT Id FROM Atlas_Change__c WHERE Id = :changeId WITH USER_MODE FOR UPDATE];
            Atlas_Change__c change = load(changeId);
            if (approve == true) Atlas_Data.assertSourceChangesAllowed(change.Conversation__c);
            if (approve != true && change.Status__c == 'Rejected' && change.Revision__c == revision
                && change.Decided_By__c == UserInfo.getUserId() && change.Decision_Note__c == (String.isBlank(note) ? null : note))
                return JSON.serialize(dto(change));
            if (change.Status__c != 'Proposed' || change.Revision__c != revision) {
                throw new Atlas_Api.AtlasException(change.Name + ' changed since you opened it (now ' + change.Status__c + ', revision '
                    + change.Revision__c + '). Reload it and review again.');
            }
            if (note != null && note.length() > 32768) throw new Atlas_Api.AtlasException('Decision notes must be at most 32,768 characters. Nothing was truncated.');
            change.Decision_Note__c = String.isBlank(note) ? null : note;
            change.Decided_By__c = UserInfo.getUserId();
            change.Decided_At__c = Datetime.now();
            if (approve != true) {
                change.Status__c = 'Rejected';
                update as user change;
                if (change.Conversation__c != null) Atlas_Data.addMessage(change.Conversation__c, 'To Agent', 'decision',
                    'I REJECTED ' + change.Name + ' revision ' + change.Revision__c + '. Nothing was deployed.\nMy note: ' + (change.Decision_Note__c ?? '(none)')
                    + '\nSend a corrected atlas-change with "change":"' + change.Name + '", or ask me a question.' + REMINDER);
                return JSON.serialize(dto(load(changeId)));
            }
            Map<String, Object> proposal = (Map<String, Object>) JSON.deserializeUntyped(fileData(change.Proposal_File__c).toString());
            Manifest m = manifest(change);
            if (activates(proposal) && !activationConfirmed) throw new Atlas_Api.AtlasException('This proposal activates a Flow. Explicitly confirm activation after reviewing the diff; ordinary edit approval is not enough.');
            Map<String, List<String>> owners = owners(m, proposal);
            Set<String> touched = touched(owners);
            preflight(m, touched, owners);
            List<String> tests = new List<String>();
            if (proposal.get('tests') instanceof List<Object>) {
                for (Object test : (List<Object>) proposal.get('tests')) tests.add(String.valueOf(test));
            }
            String level = validatedTestLevel(testLevel, false);
            if (level == 'RunSpecifiedTests' && tests.isEmpty()) throw new Atlas_Api.AtlasException('The agent listed no tests to run. Choose another test option.');
            lockDeployments();
            checkNotBusy(touched, change.Id);

            change.Deploy_Id__c = null;
            change.Test_Level__c = testLevel ?? 'Default';
            change.Status__c = 'Deploying';
            change.Result__c = JSON.serialize(new Map<String, Object>{'operation' => 'deploy', 'status' => 'Checking current source'});
            m.deployed = new List<String>(touched);
            change.Components__c = manifestJson(m);
            update as user change;
            System.enqueueJob(new Atlas_DeployJob(change.Id, null, 0));
            return JSON.serialize(dto(load(changeId)));
        } catch (Exception e) {
            throw Atlas_Api.fail(e);
        }
    }

    /**
     * Runs once per reserved approval or restore. A deployment re-reads only its backed-up
     * components; a restore change first saves the current version as its own backup.
     */
    public static void executeDeployment(Id changeId, String retrieveId, Integer attempt) {
        Atlas_Change__c change = load(changeId);
        if ((change.Status__c != 'Deploying' && change.Status__c != 'Restoring') || change.Deploy_Id__c != null
            || pending(change)?.get('outcomeUnknown') == true) return;
        Boolean restoring = change.Status__c == 'Restoring';
        try {
            Atlas_Data.assertSourceChangesAllowed(change.Conversation__c);
        } catch (Exception e) {
            Map<String, Object> result = new Map<String, Object>{'operation' => restoring ? 'restore' : 'deploy',
                'success' => 'false', 'done' => 'true', 'errorMessage' => e.getMessage(), 'outcomeUnknown' => false};
            update as user new Atlas_Change__c(Id = changeId, Status__c = 'Failed', Result__c = JSON.serialize(result));
            post(change, result);
            return;
        }
        Manifest m = manifest(change);
        Boolean restoreChange = restoring && m.restoreFrom != null;
        if (restoreChange && change.Backup_File__c == null) {
            if (saveRestoreBackup(change)) return;
            if (attempt < 3 && Atlas_DeployJob.canEnqueue(3)) {
                if (!Test.isRunningTest()) System.enqueueJob(new Atlas_DeployJob(changeId, retrieveId, attempt + 1), 1);
                return;
            }
            Atlas_Change__c locked = [SELECT Id FROM Atlas_Change__c WHERE Id = :changeId WITH USER_MODE FOR UPDATE];
            change = load(changeId);
            if (change.Status__c == 'Restoring' && change.Backup_File__c == null && change.Deploy_Id__c == null)
                failRestore(change, 'Salesforce did not finish backing up the current version in time, so nothing was restored. Try the restore again.');
            return;
        }
        // The fallback worker queued with the retrieve has nothing left to do once the backup is saved.
        if (restoreChange && retrieveId != null) return;
        Boolean submitting = false;
        String deployment;
        try {
            String level = change.Test_Level__c == 'Default' ? null : change.Test_Level__c;
            if (restoreChange) {
                Atlas_Change__c source = load(m.restoreFrom);
                if (source.Backup_File__c == null || source.Backup_Sha256__c != m.restoreSha)
                    throw new Atlas_Api.AtlasException('The backup of ' + source.Name + ' was removed or replaced, so nothing was restored.');
                // A restore queued by an older release may name bundle files; it restores their bundles.
                Blob archive = buildZip(source, restorableManifest(source), new Set<String>(logicalKeys(m.restoreKeys)), new Map<String, Blob>(), new Map<String, List<String>>());
                submitting = true;
                deployment = Atlas_Api.startDeploy(archive, level, new List<String>());
                if (String.isBlank(deployment)) throw new Atlas_Api.AtlasException('Salesforce returned no deployment ID.');
                update as user new Atlas_Change__c(Id = changeId, Deploy_Id__c = deployment);
            } else if (restoring) {
                // A restore started in place by an earlier release.
                m = reconciled(m);
                if (m == null) throw new Atlas_Api.AtlasException(change.Name + ' was saved by an older Atlas release that listed each bundle file as its own component, '
                    + 'and its files cannot each be matched to one requested bundle. Nothing was restored.');
                Set<String> existing = new Set<String>();
                for (Found f : m.found) existing.add(key(f.type, f.name));
                Set<String> touched = new Set<String>(m.deployed.isEmpty() ? new List<String>(existing) : m.deployed);
                touched.retainAll(existing);
                Blob archive = buildZip(change, m, touched, new Map<String, Blob>(), new Map<String, List<String>>());
                submitting = true;
                deployment = Atlas_Api.startDeploy(archive, level, new List<String>());
                if (String.isBlank(deployment)) throw new Atlas_Api.AtlasException('Salesforce returned no deployment ID.');
                update as user new Atlas_Change__c(Id = changeId, Deploy_Id__c = deployment);
            } else {
                String currentId = retrieveId ?? Atlas_Api.startRetrieve(m.requested);
                Atlas_Api.Retrieved current = awaitRetrieve(currentId);
                if (!current.done) {
                    if (attempt >= 30 || !Atlas_DeployJob.canEnqueue(2)) throw new Atlas_Api.AtlasException('Salesforce did not finish the pre-deployment source check within the safe background job budget. No deployment was started. Back up again and retry.');
                    if (!Test.isRunningTest()) System.enqueueJob(new Atlas_DeployJob(changeId, currentId, attempt + 1), 1);
                    return;
                }
                if (current.zip == null) throw new Atlas_Api.AtlasException('Cannot check current source: ' + (current.error ?? current.status));
                assertUnchanged(fileData(change.Backup_File__c), current.zip);
                Map<String, Object> proposal = (Map<String, Object>) JSON.deserializeUntyped(fileData(change.Proposal_File__c).toString());
                // The approval reserved exactly these components; anything else means the records disagree.
                Map<String, List<String>> owners = owners(m, proposal);
                if (!touched(owners).equals(new Set<String>(m.deployed)))
                    throw new Atlas_Api.AtlasException('The approved components no longer match the proposal. Nothing was deployed. Review the change again.');
                List<String> tests = new List<String>();
                if (proposal.get('tests') instanceof List<Object>) for (Object test : (List<Object>) proposal.get('tests')) tests.add(String.valueOf(test));
                Blob archive = buildZip(change, m, new Set<String>(m.deployed), overlay(proposal), owners);
                submitting = true;
                deployment = Atlas_Api.startDeploy(archive, level, tests);
                if (String.isBlank(deployment)) throw new Atlas_Api.AtlasException('Salesforce returned no deployment ID.');
                update as user new Atlas_Change__c(Id = changeId, Deploy_Id__c = deployment, Result__c = null);
            }
        } catch (Exception e) {
            // A SOAP fault is Salesforce refusing the request, so no deployment exists to wait for.
            if (e instanceof Atlas_Api.RejectedException && deployment == null) submitting = false;
            Map<String, Object> result = new Map<String, Object>{'operation' => restoring ? 'restore' : 'deploy', 'success' => 'false', 'done' => 'true', 'errorMessage' => e.getMessage(), 'outcomeUnknown' => submitting};
            Boolean inPlace = restoring && !restoreChange;
            String before = inPlace ? (String) pending(change)?.get('before') : null;
            if (inPlace) result.put('before', before);
            update as user new Atlas_Change__c(Id = changeId, Status__c = submitting ? change.Status__c : inPlace ? (before ?? 'Deployed') : 'Failed', Result__c = JSON.serialize(result));
            post(change, result);
            return;
        }
        // Monitoring failure must never be mistaken for an unknown submission or trigger a retry.
        enqueueCompletion(changeId, deployment, 0);
    }

    @TestVisible static Integer retrieveChecks = 12;

    /**
     * The source check of a few components usually finishes within seconds. Checking it
     * here, before any DML, starts most approved deploys at once instead of in a job queued
     * a minute later. Each check is one callout, so the loop stops well inside the callout
     * count and time limits and leaves the rest to the delayed job.
     */
    static Atlas_Api.Retrieved awaitRetrieve(String asyncId) {
        Long deadline = System.currentTimeMillis() + 25000;
        Atlas_Api.Retrieved current = Atlas_Api.checkRetrieve(asyncId);
        for (Integer i = 1; i < retrieveChecks && !current.done && System.currentTimeMillis() < deadline
            && Limits.getCallouts() + 10 < Limits.getLimitCallouts(); i++) {
            current = Atlas_Api.checkRetrieve(asyncId);
        }
        return current;
    }

    static void assertUnchanged(Blob backup, Blob current) {
        Compression.ZipReader before = new Compression.ZipReader(backup);
        Compression.ZipReader now = new Compression.ZipReader(current);
        Map<String, String> hashes = new Map<String, String>();
        for (Compression.ZipEntry file : before.getEntries()) {
            if (file.getName() != 'package.xml' && !file.getName().endsWith('/')) hashes.put(file.getName(), Atlas_Api.sha256(before.extract(file)));
        }
        for (Compression.ZipEntry file : now.getEntries()) {
            String path = file.getName();
            if (path == 'package.xml' || path.endsWith('/')) continue;
            if (hashes.remove(path) != Atlas_Api.sha256(now.extract(file))) {
                throw new Atlas_Api.AtlasException(path + ' changed in Salesforce after the backup. Nothing was deployed. Back up again and review a new diff.');
            }
        }
        if (!hashes.isEmpty()) throw new Atlas_Api.AtlasException('Backed-up files changed or were removed in Salesforce. Nothing was deployed. Back up again.');
    }

    /**
     * Deploy package: every backup file of each touched component (bundles need all their
     * files), replaced or extended by the overlay, plus a package.xml for exactly those
     * components. It is checked before it is built and read back after, so a package that
     * would drop or add files never reaches Salesforce. owners: each overlay file's component.
     */
    @TestVisible
    static Blob buildZip(Atlas_Change__c change, Manifest m, Set<String> touched, Map<String, Blob> overlay, Map<String, List<String>> owners) {
        if (!owners.keySet().equals(overlay.keySet())) throw new Atlas_Api.AtlasException('Every proposed file needs its component. Nothing was deployed.');
        Contents c = preflight(m, touched, owners);
        Compression.ZipWriter writer = new Compression.ZipWriter();
        Compression.ZipReader reader = new Compression.ZipReader(fileData(change.Backup_File__c));
        for (String path : c.paths) {
            if (overlay.containsKey(path)) {
                writer.addEntry(path, overlay.get(path));
                continue;
            }
            Compression.ZipEntry entry = reader.getEntry(path);
            if (entry == null) throw new Atlas_Api.AtlasException(path + ' is listed in the backup record of ' + change.Name + ' but missing from its backup file. Nothing was deployed. Back up again.');
            writer.addEntry(path, reader.extract(entry));
        }
        List<Atlas_Api.Component> components = new List<Atlas_Api.Component>();
        List<String> members = new List<String>(c.members);
        members.sort();
        for (String k : members) components.add(new Atlas_Api.Component(k.substringBefore(':'), k.substringAfter(':')));
        writer.addEntry('package.xml', Blob.valueOf('<?xml version="1.0" encoding="UTF-8"?><Package xmlns="' + MD_NS + '">'
            + Atlas_Api.packageXml(components) + '<version>' + Atlas_Api.VERSION + '</version></Package>'));
        Blob zip = writer.getArchive();
        verifyArchive(zip, c);
        return zip;
    }

    /** Human-selected job from Setup, after a response was lost. Never submits a second deployment. */
    @AuraEnabled
    public static String reconcileDeployment(Id changeId, String deploymentId) {
        try {
            Atlas_Change__c change = load(changeId);
            if (pending(change)?.get('outcomeUnknown') != true) throw new Atlas_Api.AtlasException('This change is not awaiting submission verification.');
            if (!Pattern.matches('0Af[A-Za-z0-9]{12}([A-Za-z0-9]{3})?', deploymentId ?? '')) throw new Atlas_Api.AtlasException('Enter the deployment ID from Salesforce Deployment Status.');
            Atlas_Api.checkDeploy(deploymentId);
            Atlas_Change__c locked = [SELECT Id FROM Atlas_Change__c WHERE Id = :changeId WITH USER_MODE FOR UPDATE];
            Atlas_Change__c current = load(changeId);
            if (current.Deploy_Id__c != null || current.Result__c != change.Result__c) throw new Atlas_Api.AtlasException('This deployment was already reconciled. Reload it.');
            Map<String,Object> result = pending(change);
            result.put('outcomeUnknown', false);
            result.put('done', 'false');
            result.put('reconciledBy', UserInfo.getUserId());
            update as user new Atlas_Change__c(Id = changeId, Deploy_Id__c = deploymentId, Result__c = JSON.serialize(result));
            enqueueCompletion(changeId, deploymentId, 0);
            return JSON.serialize(dto(load(changeId)));
        } catch (Exception e) { throw Atlas_Api.fail(e); }
    }

    @AuraEnabled
    public static String deployStatus(Id changeId) {
        try {
            return JSON.serialize(deploymentStatus(changeId, null));
        } catch (Exception e) {
            throw Atlas_Api.fail(e);
        }
    }

    static Boolean inFlight(Atlas_Change__c change) {
        return change.Status__c == 'Deploying' || change.Status__c == 'Restoring';
    }

    static Boolean terminal(Atlas_Change__c change) {
        Map<String, Object> result = pending(change);
        return TERMINAL_STATUSES.contains(change.Status__c)
            && result?.get('done') == 'true' && result.get('outcomeUnknown') != true
            && (result.get('success') == 'true' || result.get('success') == 'false')
            && (result.get('id') == null || result.get('id') == change.Deploy_Id__c);
    }

    static Map<String, Object> fullResult(Atlas_Change__c change) {
        Map<String, Object> result = pending(change);
        if (result?.get('fileId') == null) return result;
        List<ContentVersion> file = [SELECT VersionData FROM ContentVersion WHERE Id = :(Id) result.get('fileId') WITH USER_MODE];
        return file.isEmpty() ? result : (Map<String, Object>) JSON.deserializeUntyped(file[0].VersionData.toString());
    }

    /** message: what the agent was told, once the outcome is known or tracking needs a person. */
    static Map<String, Object> statusReply(Atlas_Change__c change, Boolean done, Boolean finished, Map<String, Object> result) {
        Boolean tell = done || result?.get('resultUnknown') == true || result?.get('trackingPaused') == true || result?.get('outcomeUnknown') == true;
        return new Map<String, Object>{ 'done' => done, 'finished' => finished, 'result' => result, 'change' => dto(change),
            'message' => tell ? handoff(change, result) : null };
    }

    /** Shared by browser polling and the exact-ID background worker. Never resubmits. */
    static Map<String, Object> deploymentStatus(Id changeId, String expectedId) {
        Atlas_Change__c change = load(changeId);
        if (expectedId == null && change.Status__c == 'Restoring' && change.Backup_File__c == null && change.Deploy_Id__c == null
            && manifest(change).restoreFrom != null) {
            // Browser polling moves a restore on as soon as its backup is ready.
            saveRestoreBackup(change);
            change = load(changeId);
        }
        if (expectedId != null && change.Deploy_Id__c != expectedId)
            return statusReply(change, false, false, pending(change));
        if (terminal(change)) return statusReply(change, true, false, fullResult(change));
        if (expectedId != null && !inFlight(change)) return statusReply(change, false, false, pending(change));
        if (change.Deploy_Id__c == null) {
            Map<String, Object> queued = pending(change);
            Boolean complete = change.Status__c == 'Failed' || queued?.get('done') == 'true';
            if (inFlight(change) || complete) return statusReply(change, complete, false, fullResult(change));
            throw new Atlas_Api.AtlasException(change.Name + ' has no deployment.');
        }
        Map<String, Object> result = Atlas_Api.checkDeploy(change.Deploy_Id__c);
        Boolean done = result.get('done') == 'true'
            && (result.get('success') == 'true' || result.get('success') == 'false');
        if (result.get('done') == 'true' && !done) result.put('resultUnknown', true);
        // A callout releases row locks. Recheck the exact job and revision after it,
        // including pending responses, so an old poll cannot describe a newer restore.
        Atlas_Change__c locked = [SELECT Id FROM Atlas_Change__c WHERE Id = :changeId WITH USER_MODE FOR UPDATE];
        Atlas_Change__c current = load(changeId);
        if (current.Deploy_Id__c != change.Deploy_Id__c || current.Revision__c != change.Revision__c)
            return statusReply(current, false, false, pending(current));
        if (terminal(current)) return statusReply(current, true, false, fullResult(current));
        result.put('operation', pending(current)?.get('operation') ?? (current.Status__c == 'Restoring' ? 'restore' : 'deploy'));
        if (!done || !inFlight(current)) return statusReply(current, done, false, result);

        Boolean ok = result.get('success') == 'true';
        Boolean restoring = current.Status__c == 'Restoring';
        Manifest m = manifest(current);
        Boolean inPlace = restoring && m.restoreFrom == null;
        String before = (String) pending(current)?.get('before');
        if (inPlace) {
            // Preserve the pre-restore label on failure, not a claim about test side effects.
            current.Status__c = ok ? 'Restored' : (before ?? 'Deployed');
            result.put('before', before);
        } else if (restoring) current.Status__c = ok ? 'Restored' : 'Failed';
        else current.Status__c = ok ? 'Deployed' : 'Failed';
        result.put('operation', restoring ? 'restore' : 'deploy');
        // Stamp the requested ID even if an older SOAP response omitted it.
        result.put('id', change.Deploy_Id__c);
        String text = JSON.serialize(result);
        // If the handoff fails, a background retry must not commit a terminal row
        // without its message. The callout has already finished before this savepoint.
        Savepoint save = Database.setSavepoint();
        try {
            current.Result__c = storeResult(changeId, result, text);
            update as user current;
            if (ok) Atlas_Versions.record(current, m, restoring ? 'Restore' : 'Change', Datetime.now(), !inPlace);
            post(current, result);
        } catch (Exception e) {
            Database.rollback(save);
            throw e;
        }
        return statusReply(current, true, true, result);
    }

    /** Four delayed checks at most, also bounded by the shared five-job chain budget. */
    public static void completeDeployment(Id changeId, String deploymentId, Integer attempt) {
        String problem;
        try {
            if (deploymentStatus(changeId, deploymentId).get('done') == true) return;
        } catch (Exception e) {
            problem = e.getMessage();
        }
        Atlas_Change__c current = load(changeId);
        if (!inFlight(current) || current.Deploy_Id__c != deploymentId) return;
        if (attempt < 3 && Atlas_DeployJob.canEnqueue(1)) enqueueCompletion(changeId, deploymentId, attempt + 1);
        else pauseCompletion(changeId, deploymentId, problem ?? 'Salesforce has not returned a confirmed terminal deployment result within the background polling budget.');
    }

    static void enqueueCompletion(Id changeId, String deploymentId, Integer attempt) {
        // Apex tests cannot execute nested queueable chains. Exercise each hop independently.
        if (Test.isRunningTest() && System.isQueueable()) return;
        String problem = 'The safe background queueable budget was exhausted.';
        if (Atlas_DeployJob.canEnqueue(1)) {
            try {
                System.enqueueJob(new Atlas_DeployCompletionJob(changeId, deploymentId, attempt), attempt + 1);
                return;
            } catch (Exception e) { problem = e.getMessage(); }
        }
        pauseCompletion(changeId, deploymentId, problem);
    }

    static void pauseCompletion(Id changeId, String deploymentId, String problem) {
        Atlas_Change__c locked = [SELECT Id FROM Atlas_Change__c WHERE Id = :changeId WITH USER_MODE FOR UPDATE];
        Atlas_Change__c current = load(changeId);
        if (!inFlight(current) || current.Deploy_Id__c != deploymentId) return;
        Map<String, Object> result = pending(current) ?? new Map<String, Object>();
        if (result.get('trackingPaused') == true) return;
        result.put('operation', result.get('operation') ?? (current.Status__c == 'Restoring' ? 'restore' : 'deploy'));
        result.put('done', 'false');
        result.put('id', deploymentId);
        result.put('trackingPaused', true);
        result.put('trackingMessage', problem);
        current.Result__c = JSON.serialize(result);
        update as user current;
        post(current, result);
    }

    static void post(Atlas_Change__c change, Map<String, Object> result) {
        // Edit access to the conversation can be lost after approval. The change keeps its outcome either way,
        // and a failed post must not roll the finished deployment back to Deploying.
        if (canPost(change.Conversation__c)) Atlas_Data.addMessage(change.Conversation__c, 'To Agent', 'deploy', handoff(change, result));
    }

    static void addItems(List<String> lines, List<String> items) {
        for (Integer i = 0; i < items.size() && i < HANDOFF_ITEMS; i++) lines.add(items[i]);
        if (items.size() > HANDOFF_ITEMS) lines.add('…and ' + (items.size() - HANDOFF_ITEMS) + ' more. Open the change in Atlas for the rest.');
    }

    static List<Object> listOf(Object value) {
        return value instanceof List<Object> ? (List<Object>) value : new List<Object>();
    }

    static String text(Map<String, Object> item, String field) {
        Object value = item.get(field);
        return value == null ? '' : String.valueOf(value);
    }

    /** "- classes/Foo.cls line 17:12: problem" */
    static String componentLine(Map<String, Object> e, Boolean warning) {
        String file = String.isNotBlank(text(e, 'fileName')) ? text(e, 'fileName') : (text(e, 'componentType') + ' ' + text(e, 'fullName')).trim();
        String at = String.isBlank(text(e, 'lineNumber')) ? '' : ' line ' + text(e, 'lineNumber') + (String.isBlank(text(e, 'columnNumber')) ? '' : ':' + text(e, 'columnNumber'));
        return '- ' + (warning ? '[warning] ' : '') + file + at + ': ' + text(e, 'problem');
    }

    /**
     * The agent's message about a finished, failed or unconfirmed deployment or restore:
     * what happened, the exact diagnostics it needs, and what to do next. No raw JSON;
     * the full result stays on the change.
     */
    @TestVisible
    static String handoff(Atlas_Change__c change, Map<String, Object> r) {
        if (r == null) return null;
        Boolean restore = r.get('operation') == 'restore';
        Boolean restoreChange = manifest(change).restoreFrom != null;
        String what = restore ? 'restore' : 'deployment';
        String label = restoreChange ? (change.Summary__c ?? 'restore') + ' (' + change.Name + ')' : change.Name + ' revision ' + change.Revision__c;
        List<String> lines = new List<String>();
        if (r.get('outcomeUnknown') == true) {
            lines.add('Atlas could not confirm the ' + what + ' submission for ' + label + ', so the outcome is UNKNOWN: ' + text(r, 'errorMessage'));
            lines.add('Do not retry or assume rollback. Check Salesforce Deployment Status, then reconcile its deployment ID on the Salesforce changes tab.');
        } else if (r.get('trackingPaused') == true || r.get('resultUnknown') == true || r.get('done') != 'true') {
            String why = String.isNotBlank(text(r, 'trackingMessage')) ? text(r, 'trackingMessage') : 'Salesforce has not returned a final result (' + text(r, 'status') + ').';
            lines.add('The ' + what + ' of ' + label + ' is NOT YET CONFIRMED: ' + why);
            lines.add('This is not a failure, and nothing was rolled back or resubmitted. Do not resubmit; refresh the change in Atlas to check the existing deployment.');
        } else if (r.get('success') == 'true') {
            lines.add(restore ? 'I RESTORED ' + label + '.' : 'I approved and DEPLOYED ' + label + '.');
            Integer tests = String.isBlank(text(r, 'testsRun')) ? 0 : Integer.valueOf(text(r, 'testsRun'));
            lines.add(tests > 0 ? tests + ' Apex test(s) ran and passed.' : 'No Apex tests ran.');
            if (String.isNotBlank(change.Decision_Note__c) && !restore && !restoreChange) lines.add('My note: ' + change.Decision_Note__c);
            List<String> warnings = new List<String>();
            for (Object w : listOf(r.get('componentWarnings'))) if (w instanceof Map<String, Object>) warnings.add(componentLine((Map<String, Object>) w, true));
            for (Object w : listOf(r.get('coverageWarnings'))) warnings.add('- [coverage] ' + w);
            if (!warnings.isEmpty()) {
                lines.add('Salesforce warnings:');
                addItems(lines, warnings);
            }
            if (restore) lines.add('Restoring does not delete components created later. Re-read these components before changing them; earlier backups of them are out of date.');
        } else if (String.isBlank(text(r, 'id'))) {
            lines.add((restore ? 'RESTORE FAILED for ' : 'DEPLOY FAILED for ') + label + ' before it started: ' + text(r, 'errorMessage'));
            lines.add(restore ? 'Nothing was restored.' : 'Nothing was deployed. Retrieve current source, back up again, and send a revised proposal for review. Never overwrite newer changes.');
        } else {
            lines.add((restore ? 'RESTORE FAILED for ' : 'DEPLOY FAILED for ') + label + '. Salesforce rolled back the metadata (rollbackOnError=true); tests or integrations may still have had effects.');
            if (String.isNotBlank(change.Decision_Note__c) && !restore && !restoreChange) lines.add('My note: ' + change.Decision_Note__c);
            List<String> problems = new List<String>();
            for (Object e : listOf(r.get('componentErrors'))) {
                if (e instanceof Map<String, Object>) problems.add(componentLine((Map<String, Object>) e, ((Map<String, Object>) e).get('problemType') == 'Warning'));
            }
            // Warnings on components that deployed; failed ones with warnings are already listed.
            for (Object w : listOf(r.get('componentWarnings'))) {
                if (w instanceof Map<String, Object> && text((Map<String, Object>) w, 'success') == 'true') problems.add(componentLine((Map<String, Object>) w, true));
            }
            for (Object f : listOf(r.get('testFailures'))) {
                if (!(f instanceof Map<String, Object>)) continue;
                Map<String, Object> failure = (Map<String, Object>) f;
                problems.add('- test ' + text(failure, 'test') + ': ' + text(failure, 'message')
                    + (String.isBlank(text(failure, 'stackTrace')) ? '' : '\n' + text(failure, 'stackTrace')));
            }
            for (Object w : listOf(r.get('coverageWarnings'))) problems.add('- [coverage] ' + w);
            for (Object w : listOf(r.get('flowCoverageWarnings'))) {
                if (w instanceof Map<String, Object>) problems.add('- [flow coverage] ' + (text((Map<String, Object>) w, 'flowName') + ' ' + text((Map<String, Object>) w, 'message')).trim());
            }
            if (!problems.isEmpty()) {
                lines.add('Salesforce reported:');
                addItems(lines, problems);
            }
            if (String.isNotBlank(text(r, 'errorMessage'))) lines.add(text(r, 'errorMessage'));
            lines.add(restore ? 'Nothing was restored.' : 'Fix these, then send a corrected atlas-change with "change":"' + change.Name + '". It needs a new review and approval.');
        }
        return String.join(lines, '\n') + REMINDER;
    }

    /** Keep list views small without cutting a JSON document or losing error details. */
    static String storeResult(Id changeId, Map<String, Object> result, String text) {
        if (text.length() <= 131072) return text;
        ContentVersion file = new ContentVersion(Title = 'Atlas deployment result', PathOnClient = 'deployment-result.json',
            VersionData = Blob.valueOf(text), FirstPublishLocationId = changeId);
        insert as user file;
        Map<String, Object> summary = new Map<String, Object>();
        for (String field : new List<String>{'id', 'operation', 'before', 'done', 'success', 'status', 'testsRun', 'numberComponentErrors', 'numberTestErrors'}) {
            summary.put(field, result.get(field));
        }
        summary.put('fileId', file.Id);
        summary.put('fullResultUrl', downloadUrl(file.Id));
        summary.put('errorMessage', 'Full Salesforce result saved as a file. Open this change for all details.');
        return JSON.serialize(summary);
    }

    static Map<String, Object> pending(Atlas_Change__c change) {
        try {
            return (Map<String, Object>) JSON.deserializeUntyped(change.Result__c);
        } catch (Exception e) {
            return new Map<String, Object>();
        }
    }

    static String validatedTestLevel(String level, Boolean restoring) {
        if (String.isBlank(level) || level == 'Default') return null;
        Set<String> allowed = new Set<String>{'RunLocalTests', 'RunAllTestsInOrg', 'NoTestRun'};
        if (!restoring) allowed.add('RunSpecifiedTests');
        if (!allowed.contains(level)) throw new Atlas_Api.AtlasException('Unsupported test level. Choose a test option offered by Atlas. Restore cannot use a proposal-specific test list.');
        return level;
    }

    // ---------------------------------------------------------------- restore

    /**
     * The source's backed-up component keys to restore: the requested ones, or by default
     * everything the change deployed that existed before it.
     */
    static List<String> restoreKeys(Atlas_Change__c source, String componentsJson) {
        Manifest m = restorableManifest(source);
        Map<String, String> saved = new Map<String, String>();
        for (Found f : m.found) saved.put(Atlas_Versions.componentKey(key(f.type, f.name)).toLowerCase(), key(f.type, f.name));
        Object requested = String.isBlank(componentsJson) ? null : JSON.deserializeUntyped(componentsJson);
        Boolean explicit = requested instanceof List<Object> && !((List<Object>) requested).isEmpty();
        List<String> wanted = new List<String>();
        if (explicit) {
            for (Atlas_Api.Component c : Atlas_Api.components(requested, MAX_COMPONENTS)) wanted.add(key(c.type, c.name));
        } else wanted.addAll(m.deployed.isEmpty() ? saved.values() : m.deployed);
        Set<String> keys = new Set<String>();
        for (String k : wanted) {
            String match = saved.get(Atlas_Versions.componentKey(k).toLowerCase());
            if (match != null) keys.add(match);
            else if (explicit) throw new Atlas_Api.AtlasException(k.replace(':', ' ') + ' is not in the backup of ' + source.Name + ', so it cannot be restored from it.');
        }
        if (keys.isEmpty()) throw new Atlas_Api.AtlasException('Nothing to restore: the change only created new components. Delete those in Setup if needed.');
        return new List<String>(keys);
    }

    static Boolean restoreActivates(Atlas_Change__c source, Manifest m, Set<String> touched) {
        Compression.ZipReader reader;
        List<Object> flows = new List<Object>();
        for (String path : m.files.keySet()) {
            if (!path.startsWith('flows/') && !path.startsWith('flowDefinitions/')) continue;
            for (String owner : m.files.get(path)) if (touched.contains(owner)) {
                reader = reader ?? new Compression.ZipReader(fileData(source.Backup_File__c));
                Compression.ZipEntry entry = reader.getEntry(path);
                if (entry == null) throw new Atlas_Api.AtlasException(path + ' is missing from the backup of ' + source.Name + ', so it cannot be restored.');
                flows.add(new Map<String,Object>{'path' => path, 'content' => reader.extract(entry).toString()});
                break;
            }
        }
        return activates(new Map<String,Object>{'files' => flows});
    }

    static void restorable(Atlas_Change__c source) {
        if (!TERMINAL_STATUSES.contains(source.Status__c))
            throw new Atlas_Api.AtlasException(source.Name + ' is ' + source.Status__c + '; only finished changes can be restored.');
        if (source.Backup_File__c == null)
            throw new Atlas_Api.AtlasException('The backup of ' + source.Name + ' was removed to free storage, so it cannot be restored.');
    }

    /** The confirmation was for this exact backup. */
    static void checkSnapshot(Atlas_Change__c source, Map<String, Object> expected) {
        restorable(source);
        if (expected == null || expected.get('revision') == null || String.isBlank(String.valueOf(expected.get('backupSha256') ?? '')))
            throw new Atlas_Api.AtlasException('Restore requires a reviewed restore plan. Reload and review again.');
        if (source.Revision__c != Decimal.valueOf(String.valueOf(expected.get('revision'))) || source.Backup_Sha256__c != expected.get('backupSha256'))
            throw new Atlas_Api.AtlasException(source.Name + ' changed since you opened the restore confirmation. Reload and review again.');
    }

    /** ...and for these components' newest versions, so it never replaces a version nobody reviewed. */
    static void checkLatest(List<Map<String, Object>> plan, Object latest) {
        Map<String, Object> seen = latest instanceof Map<String, Object> ? (Map<String, Object>) latest : new Map<String, Object>();
        for (Map<String, Object> item : plan) {
            if (!String.valueOf(seen.get((String) item.get('key')) ?? '-').equals(item.get('latestId')))
                throw new Atlas_Api.AtlasException(((String) item.get('component')).replace(':', ' ')
                    + ' has a newer version since you opened the restore confirmation. Reload and review again.');
        }
    }

    /**
     * Approvals and restores of different changes each lock only their own record, so two of
     * them could both pass checkNotBusy before either commits. They queue on this shared row
     * instead; the reservation commits with the lock, and the next one sees it.
     */
    @TestVisible
    static void lockDeployments() {
        try {
            upsert as user new Atlas_Setting__c(Name = 'Atlas deployment lock', Key__c = 'deploy-lock') Key__c;
            Atlas_Setting__c serial = [SELECT Id FROM Atlas_Setting__c WHERE Key__c = 'deploy-lock' WITH USER_MODE FOR UPDATE];
        } catch (DmlException e) {
            if (e.getDmlType(0) == StatusCode.DUPLICATE_VALUE || e.getDmlType(0) == StatusCode.UNABLE_TO_LOCK_ROW)
                throw new Atlas_Api.AtlasException('Another approval or restore is starting. Try again in a moment; nothing was deployed.');
            throw e;
        }
    }

    /** The component record of a change, which must fit its long text field. */
    @TestVisible
    static String manifestJson(Manifest m) {
        String value = JSON.serialize(m);
        if (value.length() > manifestChars)
            throw new Atlas_Api.AtlasException('These components hold too many files to record on one change (' + value.length().format() + ' of ' + manifestChars.format()
                + ' characters). Back up fewer components per change. Nothing was saved.');
        return value;
    }

    /** Two deployments of one component at once would race, so the second one waits. */
    @TestVisible
    static void checkNotBusy(Set<String> keys, Id exceptId) {
        Set<String> mine = new Set<String>();
        for (String k : keys) mine.add(Atlas_Versions.componentKey(logicalKey(k)).toLowerCase());
        for (Atlas_Change__c other : [
            SELECT Id, Name, Status__c, Components__c FROM Atlas_Change__c WHERE Status__c IN ('Deploying', 'Restoring') AND Id != :exceptId WITH USER_MODE LIMIT 200
        ]) {
            for (String k : manifest(other).deployed) {
                if (mine.contains(Atlas_Versions.componentKey(logicalKey(k)).toLowerCase()))
                    throw new Atlas_Api.AtlasException(other.Name + ' is ' + other.Status__c.toLowerCase() + ' ' + k.replace(':', ' ') + ' right now. Wait for it to finish, then reload.');
            }
        }
    }

    static Boolean canPost(Id conversationId) {
        if (conversationId == null) return false;
        List<UserRecordAccess> access = [SELECT RecordId, HasEditAccess FROM UserRecordAccess WHERE UserId = :UserInfo.getUserId() AND RecordId = :conversationId];
        return !access.isEmpty() && access[0].HasEditAccess;
    }

    /** What restoring from the source change's backup puts back, and which versions it replaces. */
    @AuraEnabled
    public static String restorePlan(Id sourceChangeId, String componentsJson) {
        try {
            Atlas_Versions.backfill();
            Atlas_Change__c source = load(sourceChangeId);
            restorable(source);
            List<String> keys = restoreKeys(source, componentsJson);
            return JSON.serialize(new Map<String, Object>{
                'source' => new Map<String, Object>{ 'id' => source.Id, 'name' => source.Name, 'summary' => source.Summary__c,
                    'revision' => source.Revision__c, 'backupSha256' => source.Backup_Sha256__c },
                'components' => Atlas_Versions.plan(source, keys),
                'activatesFlow' => restoreActivates(source, restorableManifest(source), new Set<String>(keys))
            });
        } catch (Exception e) {
            throw Atlas_Api.fail(e);
        }
    }

    /**
     * Starts a restore as a new change. It backs up the current version first, then
     * deploys the source's backup of the chosen components, so it can be undone the same way.
     * expectedJson pins what the person reviewed: {revision, backupSha256, latest: {key: latestId}}.
     */
    @AuraEnabled
    public static String startRestore(Id sourceChangeId, String componentsJson, String testLevel, Boolean activationConfirmed, String expectedJson) {
        try {
            if (!Atlas_Change__c.SObjectType.getDescribe().isCreateable()) throw new Atlas_Api.AtlasException('You do not have access to save Atlas changes.');
            Map<String, Object> expected = String.isBlank(expectedJson) ? null : (Map<String, Object>) JSON.deserializeUntyped(expectedJson);
            Atlas_Change__c source = load(sourceChangeId);
            Atlas_Data.assertSourceChangesAllowed(source.Conversation__c);
            checkSnapshot(source, expected);
            List<String> keys = restoreKeys(source, componentsJson);
            Manifest sm = restorableManifest(source);
            if (activationConfirmed != true && restoreActivates(source, sm, new Set<String>(keys)))
                throw new Atlas_Api.AtlasException('The backup activates a Flow. Explicitly confirm restoring Flow activation before proceeding.');
            String level = validatedTestLevel(testLevel, true) ?? 'Default';
            List<Map<String, Object>> plan = Atlas_Versions.plan(source, keys);
            checkLatest(plan, expected.get('latest'));
            checkNotBusy(new Set<String>(keys), null);
            Set<String> chosen = new Set<String>(keys);
            List<Atlas_Api.Component> components = new List<Atlas_Api.Component>();
            for (Found f : sm.found) if (chosen.contains(key(f.type, f.name))) components.add(new Atlas_Api.Component(f.type, f.name));

            // Callouts must come before any database write in the same request.
            String asyncId = Atlas_Api.startRetrieve(components);
            Atlas_Change__c locked = [SELECT Id FROM Atlas_Change__c WHERE Id = :sourceChangeId WITH USER_MODE FOR UPDATE];
            source = load(sourceChangeId);
            checkSnapshot(source, expected);
            checkLatest(Atlas_Versions.plan(source, keys), expected.get('latest'));
            lockDeployments();
            checkNotBusy(chosen, null);

            Map<String, Object> only = plan.size() == 1 ? plan[0] : null;
            String summary = only != null
                ? 'Restore ' + ((String) only.get('component')).replace(':', ' ') + ' to v' + only.get('restoreTo') + ' (' + only.get('label') + ')'
                : 'Restore ' + plan.size() + ' components to how they were before ' + source.Name;
            Manifest m = new Manifest();
            m.requested = components;
            m.retrieveId = asyncId;
            for (Atlas_Api.Component c : components) if (sm.typePaths.containsKey(c.type)) m.typePaths.put(c.type, sm.typePaths.get(c.type));
            m.restoreFrom = source.Id;
            m.restoreKeys = keys;
            m.deployed = keys;
            m.restoreSha = source.Backup_Sha256__c;
            m.versionLabel = only != null ? 'Restored to v' + only.get('restoreTo') : 'Restored to before ' + source.Name;
            Atlas_Change__c change = new Atlas_Change__c(Status__c = 'Restoring', Revision__c = 1, Summary__c = summary.abbreviate(255),
                Conversation__c = canPost(source.Conversation__c) ? source.Conversation__c : null,
                Decided_By__c = UserInfo.getUserId(), Decided_At__c = Datetime.now(), Test_Level__c = level, Components__c = manifestJson(m),
                Result__c = JSON.serialize(new Map<String, Object>{ 'operation' => 'restore', 'status' => 'Backing up the current version', 'done' => 'false' }));
            insert as user change;
            // Finishes the restore even if the browser closes before the backup is ready.
            if (Atlas_DeployJob.canEnqueue(1)) System.enqueueJob(new Atlas_DeployJob(change.Id, asyncId, 0), 1);
            return JSON.serialize(dto(load(change.Id)));
        } catch (Exception e) {
            throw Atlas_Api.fail(e);
        }
    }

    /** Restore step 1: saves the current version as the restore's own backup, then queues the deploy. False while Salesforce is still retrieving. */
    static Boolean saveRestoreBackup(Atlas_Change__c change) {
        Atlas_Api.Retrieved result;
        try {
            result = Atlas_Api.checkRetrieve(manifest(change).retrieveId);
        } catch (Exception e) {
            return false; // A status error is retried; nothing was saved or deployed.
        }
        if (!result.done) return false;
        Atlas_Change__c locked = [SELECT Id FROM Atlas_Change__c WHERE Id = :change.Id WITH USER_MODE FOR UPDATE];
        change = load(change.Id);
        if (change.Status__c != 'Restoring' || change.Backup_File__c != null || change.Deploy_Id__c != null) return true;
        if (result.zip == null) {
            failRestore(change, 'Could not back up the current version first, so nothing was restored: ' + (result.error ?? result.status));
            return true;
        }
        // After the last callout: a full File store or a lost queue slot ends the restore cleanly instead of leaving it Restoring.
        Savepoint beforeBackup = Database.setSavepoint();
        try {
            saveBackup(change, manifest(change), result, 'Version before ' + change.Name + ': ' + change.Summary__c);
            change.Result__c = JSON.serialize(new Map<String, Object>{ 'operation' => 'restore', 'status' => 'Queued', 'done' => 'false' });
            update as user change;
            // Apex tests cannot execute nested queueable chains. Exercise each hop independently.
            if (Test.isRunningTest() && System.isQueueable()) return true;
            if (!Atlas_DeployJob.canEnqueue(2)) {
                failRestore(change, 'Could not queue the restore, so nothing was restored. The current version was backed up. Try the restore again.');
                return true;
            }
            System.enqueueJob(new Atlas_DeployJob(change.Id, null, 0));
        } catch (Exception e) {
            Database.rollback(beforeBackup);
            failRestore(load(change.Id), 'Could not save the backup of the current version, so nothing was restored: ' + e.getMessage());
        }
        return true;
    }

    static void failRestore(Atlas_Change__c change, String message) {
        Map<String, Object> result = new Map<String, Object>{ 'operation' => 'restore', 'success' => 'false', 'done' => 'true', 'errorMessage' => message, 'outcomeUnknown' => false };
        update as user new Atlas_Change__c(Id = change.Id, Status__c = 'Failed', Result__c = JSON.serialize(result));
        post(change, result);
    }

    @AuraEnabled
    public static String listChanges() {
        try {
            List<Map<String, Object>> rows = new List<Map<String, Object>>();
            for (Atlas_Change__c change : [
                SELECT Id, Name, Status__c, Summary__c, Conversation__c, Components__c, Backup_File__c, Backup_Sha256__c, Proposal_File__c,
                    Revision__c, Deploy_Id__c, Test_Level__c, Result__c, Decision_Note__c, Decided_By__c, Decided_By__r.Name, Decided_At__c, CreatedBy.Name, CreatedDate,
                    Files_Removed__c
                FROM Atlas_Change__c WITH USER_MODE ORDER BY CreatedDate DESC LIMIT 201
            ]) rows.add(dto(change));
            if (rows.size() > 200) throw new Atlas_Api.AtlasException('Use changePage to read the complete change history. No partial list was returned.');
            return JSON.serialize(rows);
        } catch (Exception e) {
            throw Atlas_Api.fail(e);
        }
    }

    @AuraEnabled
    public static String changePage(Id beforeId) {
        try {
            List<Atlas_Change__c> records = Database.query('SELECT Id, Name, Status__c, Summary__c, Conversation__c, Components__c, Backup_File__c, Backup_Sha256__c, Proposal_File__c, '
                + 'Revision__c, Deploy_Id__c, Test_Level__c, Result__c, Decision_Note__c, Decided_By__c, Decided_By__r.Name, Decided_At__c, CreatedBy.Name, CreatedDate, Files_Removed__c FROM Atlas_Change__c'
                + (beforeId == null ? '' : ' WHERE Id < :beforeId') + ' ORDER BY Id DESC LIMIT 51', AccessLevel.USER_MODE);
            Boolean more = records.size() > 50;
            if (more) records.remove(50);
            List<Map<String,Object>> rows = new List<Map<String,Object>>();
            for (Atlas_Change__c row : records) rows.add(dto(row));
            return JSON.serialize(new Map<String,Object>{'items' => rows, 'nextCursor' => more ? records[49].Id : null, 'hasMore' => more});
        } catch (Exception e) { throw Atlas_Api.fail(e); }
    }

    static Map<String, Object> dto(Atlas_Change__c change) {
        Manifest m = manifest(change);
        return new Map<String, Object>{
            'id' => change.Id, 'name' => change.Name, 'status' => change.Status__c, 'summary' => change.Summary__c,
            'conversationId' => change.Conversation__c, 'requested' => m.requested, 'found' => m.found, 'missing' => m.missing,
            'deployed' => m.deployed, 'problems' => m.problems, 'blocked' => m.blocked, 'files' => m.files.keySet(),
            'needsBackup' => fileLevel(m) && m.restoreFrom == null,
            'backupUrl' => downloadUrl(change.Backup_File__c), 'backupSha256' => change.Backup_Sha256__c,
            'proposalUrl' => downloadUrl(change.Proposal_File__c), 'revision' => change.Revision__c,
            'deployId' => change.Deploy_Id__c, 'testLevel' => change.Test_Level__c,
            'result' => String.isBlank(change.Result__c) ? null : JSON.deserializeUntyped(change.Result__c),
            'decisionNote' => change.Decision_Note__c, 'decidedBy' => change.Decided_By__r?.Name, 'decidedAt' => change.Decided_At__c,
            'createdBy' => change.CreatedBy?.Name, 'created' => change.CreatedDate,
            'restoreFrom' => m.restoreFrom, 'filesRemoved' => change.Files_Removed__c
        };
    }
}
