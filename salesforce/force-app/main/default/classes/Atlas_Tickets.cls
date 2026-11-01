/**
 * Shared Jira ticket drafts and mirrors. Jira itself stays manual: tickets leave by
 * CSV import, updates are copied by hand, and a Jira CSV export brings keys and
 * statuses back.
 */
public with sharing class Atlas_Tickets {
    static final Integer MAX_PENDING_CHARS = 120000;

    public class Ticket {
        @AuraEnabled public String id;
        @AuraEnabled public String atlasId;
        @AuraEnabled public String summary;
        @AuraEnabled public String description;
        @AuraEnabled public String issueType;
        @AuraEnabled public String epicName;
        @AuraEnabled public String epicId;
        @AuraEnabled public String epicAtlasId;
        @AuraEnabled public String epicKey;
        @AuraEnabled public String epicSummary;
        @AuraEnabled public String jiraKey;
        @AuraEnabled public String projectKey;
        @AuraEnabled public String stage;
        @AuraEnabled public String jiraStatus;
        @AuraEnabled public String statusCategory;
        @AuraEnabled public String assigneeId;
        @AuraEnabled public String assigneeName;
        @AuraEnabled public String reporterId;
        @AuraEnabled public String reporterName;
        @AuraEnabled public String priority;
        @AuraEnabled public Date dueDate;
        @AuraEnabled public String dueDateSource;
        @AuraEnabled public String dueDateNote;
        @AuraEnabled public String dependsOn;
        @AuraEnabled public String conversationId;
        @AuraEnabled public List<Object> pendingUpdates;
        @AuraEnabled public Integer pendingCount = 0;
        @AuraEnabled public Datetime exportedAt;
        @AuraEnabled public String exportBatch;
        @AuraEnabled public Datetime jiraUpdated;
        @AuraEnabled public Datetime modified;
        @AuraEnabled public String modifiedBy;
        @AuraEnabled public String version;
        @AuraEnabled public Map<String, Object> planning;
        @AuraEnabled public Object raw;
        @AuraEnabled public String rawFileId;
        @AuraEnabled public String exportFileId;
        @AuraEnabled public Decimal revision;
    }

    /** Lists leave out the update history, which can be long; see withLegacyCounts. */
    static final String SUMMARY_FIELDS = 'Id, Name, Summary__c, Issue_Type__c, Epic_Name__c, Epic__c, Epic__r.Name, Epic__r.Jira_Key__c, '
        + 'Epic__r.Summary__c, Epic_Key__c, Jira_Key__c, Project_Key__c, Stage__c, Jira_Status__c, Jira_Status_Category__c, '
        + 'Assignee__c, Assignee__r.Name, Reporter__c, Reporter__r.Name, Priority__c, Due_Date__c, Due_Date_Source__c, '
        + 'Due_Date_Note__c, Depends_On__c, Conversation__c, Exported_At__c, Export_Batch__c, '
        + 'Jira_Updated__c, Planning__c, Raw_File__c, Export_File__c, Import_Revision__c, LastModifiedDate, LastModifiedBy.Name';
    static final String FIELDS = SUMMARY_FIELDS + ', Pending_Updates__c';

    /**
     * Tickets saved before the pending count was stored in Planning__c still need their history
     * to count it. Only those rows read the history, so a page of long histories stays off the heap.
     */
    static List<Atlas_Ticket__c> withLegacyCounts(List<Atlas_Ticket__c> rows) {
        Set<Id> legacy = new Set<Id>();
        for (Atlas_Ticket__c r : rows) if (!planning(r).containsKey('pendingCount')) legacy.add(r.Id);
        if (legacy.isEmpty()) return rows;
        Map<Id, Atlas_Ticket__c> history = new Map<Id, Atlas_Ticket__c>(
            [SELECT Pending_Updates__c FROM Atlas_Ticket__c WHERE Id IN :legacy WITH USER_MODE]);
        for (Atlas_Ticket__c r : rows) if (legacy.contains(r.Id))
            r.Pending_Updates__c = history.containsKey(r.Id) ? history.get(r.Id).Pending_Updates__c : null;
        return rows;
    }

    static Ticket dto(Atlas_Ticket__c r, Boolean withDescription) { return dto(r, withDescription, withDescription); }

    static Ticket dto(Atlas_Ticket__c r, Boolean withDescription, Boolean withHistory) {
        Ticket t = new Ticket();
        t.id = r.Id;
        t.atlasId = r.Name;
        t.summary = r.Summary__c;
        if (withDescription) t.description = r.Description__c;
        t.issueType = r.Issue_Type__c;
        t.epicName = r.Epic_Name__c;
        t.epicId = r.Epic__c;
        t.epicAtlasId = r.Epic__r?.Name;
        t.epicKey = r.Epic__r?.Jira_Key__c ?? r.Epic_Key__c;
        t.epicSummary = r.Epic__r?.Summary__c;
        t.jiraKey = r.Jira_Key__c;
        t.projectKey = r.Project_Key__c;
        t.stage = r.Stage__c;
        t.jiraStatus = r.Jira_Status__c;
        t.statusCategory = r.Jira_Status_Category__c;
        t.assigneeId = r.Assignee__c;
        t.assigneeName = r.Assignee__r?.Name;
        t.reporterId = r.Reporter__c;
        t.reporterName = r.Reporter__r?.Name;
        t.priority = r.Priority__c;
        t.dueDate = r.Due_Date__c;
        t.dueDateSource = r.Due_Date_Source__c;
        t.dueDateNote = r.Due_Date_Note__c;
        t.dependsOn = r.Depends_On__c;
        t.conversationId = r.Conversation__c;
        t.planning = planning(r);
        t.rawFileId = r.Raw_File__c;
        t.exportFileId = r.Export_File__c;
        t.revision = r.Import_Revision__c;
        if (t.planning.containsKey('pendingCount')) t.pendingCount = Integer.valueOf(t.planning.get('pendingCount'));
        else if (!String.isBlank(r.Pending_Updates__c) && r.Pending_Updates__c.startsWith('[')) {
            for (Object item : pending(r)) if (((Map<String, Object>) item).get('status') == 'pending') t.pendingCount++;
        }
        t.exportedAt = r.Exported_At__c;
        t.exportBatch = r.Export_Batch__c;
        t.jiraUpdated = r.Jira_Updated__c;
        t.modified = r.LastModifiedDate;
        t.modifiedBy = r.LastModifiedBy?.Name;
        String description = t.description;
        t.description = null;
        t.version = Atlas_Api.sha256(Blob.valueOf(JSON.serialize(t)));
        t.description = description;
        if (withHistory) t.pendingUpdates = pending(r);
        return t;
    }

    static List<Object> pending(Atlas_Ticket__c r) {
        if (String.isBlank(r.Pending_Updates__c)) return new List<Object>();
        Object stored = JSON.deserializeUntyped(r.Pending_Updates__c);
        if (stored instanceof Map<String, Object>) {
            Id fileId = (Id) ((Map<String, Object>) stored).get('file');
            stored = JSON.deserializeUntyped([SELECT VersionData FROM ContentVersion WHERE Id = :fileId WITH USER_MODE].VersionData.toString());
        }
        return (List<Object>) stored;
    }

    /** Compatibility entry point; use boardPage for a complete board. Never silently truncate. */
    @AuraEnabled
    public static List<Ticket> board(Boolean includeArchived) {
        BoardPage page = boardPage(includeArchived, null, 200);
        if (page.nextCursor != null) throw new Atlas_Api.AtlasException('Use boardPage to read the complete board.');
        return page.tickets;
    }

    public class BoardPage {
        @AuraEnabled public List<Ticket> tickets = new List<Ticket>();
        @AuraEnabled public String nextCursor;
    }

    @AuraEnabled
    public static BoardPage boardPage(Boolean includeArchived, String afterId, Integer pageSize) {
        try {
            Integer size = pageSize == null ? 200 : Math.max(1, Math.min(200, pageSize));
            Integer fetch = size + 1;
            Id cursor = String.isBlank(afterId) ? null : (Id) afterId;
            String soql = 'SELECT ' + SUMMARY_FIELDS + ' FROM Atlas_Ticket__c WHERE Id != null'
                + (includeArchived == true ? '' : ' AND Stage__c != \'Archived\'')
                + (cursor == null ? '' : ' AND Id > :cursor') + ' ORDER BY Id LIMIT :fetch';
            List<Atlas_Ticket__c> records = Database.query(soql, AccessLevel.USER_MODE);
            BoardPage page = new BoardPage();
            if (records.size() > size) {
                records.remove(size);
                page.nextCursor = records[size - 1].Id;
            }
            for (Atlas_Ticket__c r : withLegacyCounts(records)) page.tickets.add(dto(r, false));
            return page;
        } catch (Exception e) { throw Atlas_Api.fail(e); }
    }

    @AuraEnabled
    public static Ticket getTicket(Id ticketId) {
        try {
            List<Atlas_Ticket__c> rows = Database.query('SELECT Description__c, ' + FIELDS + ' FROM Atlas_Ticket__c WHERE Id = :ticketId', AccessLevel.USER_MODE);
            if (rows.isEmpty()) throw new Atlas_Api.AtlasException('That ticket was deleted or is not shared with you. Reload the board.');
            Ticket t = dto(rows[0], true);
            if (t.rawFileId != null) {
                Id fileId = t.rawFileId;
                Map<String, Object> content = (Map<String, Object>) JSON.deserializeUntyped([SELECT VersionData FROM ContentVersion WHERE Id = :fileId WITH USER_MODE].VersionData.toString());
                t.raw = content.containsKey('snapshots') ? ((Map<String, Object>) content.get('snapshots')).get(t.jiraKey) : content.get('raw');
            }
            return t;
        } catch (Exception e) {
            throw Atlas_Api.fail(e);
        }
    }

    public static List<Ticket> forConversation(Id conversationId) {
        List<Ticket> result = new List<Ticket>();
        for (Atlas_Ticket__c r : withLegacyCounts(Database.query('SELECT ' + SUMMARY_FIELDS + ' FROM Atlas_Ticket__c WHERE Conversation__c = :conversationId ORDER BY Name', AccessLevel.USER_MODE))) {
            result.add(dto(r, false));
        }
        return result;
    }

    /**
     * Agent "tickets" request. Filters: owner (me, team, reports, everyone, unassigned or
     * a list of names/aliases/Jira IDs), keys (Jira keys or TKT IDs), text, stage,
     * status (To Do, In Progress, Done), epicsOnly, conversation, description, limit.
     */
    public static String agentQuery(Map<String, Object> request) {
        List<String> filters = new List<String>();
        Integer requested = request.get('limit') == null ? 100 : Integer.valueOf(String.valueOf(request.get('limit')));
        if (requested < 1 || requested > 500) throw new Atlas_Api.AtlasException('Ticket limit must be 1–500; follow nextCursor for all matching tickets.');
        Integer max = Math.min(request.get('description') == true ? 10 : 200, requested), fetch = max + 1;
        Id cursor = request.get('cursor') == null ? null : (Id)request.get('cursor');
        if (cursor != null) filters.add('Id > :cursor');
        Set<Id> owners = owners(request.get('owner'));
        if (owners != null) filters.add(owners.isEmpty() ? 'Assignee__c = null' : 'Assignee__c IN :owners');
        List<String> keys = new List<String>();
        if (request.get('keys') instanceof List<Object>) {
            for (Object key : (List<Object>) request.get('keys')) keys.add(String.valueOf(key).trim());
            filters.add('(Jira_Key__c IN :keys OR Name IN :keys)');
        }
        // A bind variable needs no quote escaping; only LIKE wildcards are escaped.
        String text = request.get('text') instanceof String
            ? '%' + ((String) request.get('text')).replace('\\', '\\\\').replace('%', '\\%').replace('_', '\\_') + '%' : null;
        if (text != null) filters.add('Summary__c LIKE :text');
        String stage = (String) request.get('stage');
        if (stage != null) filters.add('Stage__c = :stage');
        else if (keys.isEmpty()) filters.add('Stage__c != \'Archived\'');
        String status = (String) request.get('status');
        if (status != null) filters.add('Jira_Status_Category__c = :status');
        if (request.get('epicsOnly') == true) filters.add('Issue_Type__c = \'Epic\'');
        String conversation = (String) request.get('conversation');
        if (conversation != null) filters.add('Conversation__c = :conversation');
        Boolean withDescription = request.get('description') == true;
        String soql = 'SELECT ' + (withDescription ? 'Description__c, ' : '') + SUMMARY_FIELDS + ' FROM Atlas_Ticket__c'
            + (filters.isEmpty() ? '' : ' WHERE ' + String.join(filters, ' AND ')) + ' ORDER BY Id LIMIT :fetch';
        List<Ticket> result = new List<Ticket>();
        String nextCursor;
        for (Atlas_Ticket__c r : withLegacyCounts(Database.query(soql, AccessLevel.USER_MODE))) {
            if (result.size() == max) { nextCursor = result[result.size()-1].id; break; }
            result.add(dto(r, withDescription, false));
        }
        return JSON.serialize(new Map<String, Object>{ 'count' => result.size(), 'tickets' => result, 'nextCursor'=>nextCursor,
            'hasMore'=>nextCursor != null, 'pageSize'=>max, 'pendingHistoryIncluded'=>false,
            'scope'=>'Accessible tickets matching these filters, ordered by Id. Repeat the same filters with nextCursor; not an atomic snapshot. Pending checklist counts are included, full history is available on the native board.' }, true);
    }

    public static Set<Id> liveOwnerIds(Object owner) { return owners(owner); }

    /** Person IDs for an owner filter; null means no filter and an empty set means unassigned. */
    static Set<Id> owners(Object owner) {
        if (owner == null || owner == 'everyone') return null;
        Set<Id> ids = new Set<Id>();
        if (owner == 'unassigned') return ids;
        List<Atlas_Person__c> people = [
            SELECT Id, Name, Aliases__c, Alias_List__c, Jira_Account_Id__c, User__c, Manager__r.User__c FROM Atlas_Person__c WHERE Active__c = true WITH USER_MODE
        ];
        if (owner == 'me' || owner == 'team' || owner == 'reports') {
            for (Atlas_Person__c p : people) {
                Boolean isMe = p.User__c == UserInfo.getUserId();
                Boolean isReport = p.Manager__r?.User__c == UserInfo.getUserId();
                if ((owner != 'reports' && isMe) || (owner != 'me' && isReport)) ids.add(p.Id);
            }
            if (ids.isEmpty()) throw new Atlas_Api.AtlasException('No people match "' + owner + '". Add yourself and your direct reports in Team & Jira.');
            return ids;
        }
        List<Object> names = owner instanceof List<Object> ? (List<Object>) owner : new List<Object>{ owner };
        for (Object name : names) {
            if (Atlas_Identity.isManagerRole(String.valueOf(name))) {
                Map<String,Object> manager = Atlas_Identity.managerIdentity(String.valueOf(name));
                ids.add((Id)manager.get('personId'));
                continue;
            }
            String key = Atlas_Data.aliasKey(String.valueOf(name));
            Id match = null;
            for (Atlas_Person__c p : people) {
                Set<String> keys = new Set<String>();
                for (String alias : Atlas_Identity.names(p)) keys.add(Atlas_Data.aliasKey(alias));
                keys.add(Atlas_Data.aliasKey(String.valueOf(p.Id)));
                keys.add(Atlas_Data.aliasKey(String.valueOf(p.User__c)));
                keys.add(Atlas_Data.aliasKey(p.Name));
                if (keys.contains(key) || p.Jira_Account_Id__c == String.valueOf(name).trim()) {
                    if (match != null && match != p.Id) throw new Atlas_Api.AtlasException('Ambiguous identity "' + name + '". Reconcile the people list first.');
                    match = p.Id;
                }
            }
            if (match == null) throw new Atlas_Api.AtlasException('No person named or aliased "' + name + '". Ask for the people list first.');
            ids.add(match);
        }
        return ids;
    }

    static Map<String, Object> planning(Atlas_Ticket__c r) {
        return String.isBlank(r.Planning__c) ? new Map<String, Object>() : (Map<String, Object>) JSON.deserializeUntyped(r.Planning__c);
    }

    static Id file(String name, String content, Id parentId) {
        if (content.length() > 1500000) throw new Atlas_Api.AtlasException('File exceeds 1,500,000 characters; use smaller chunks. Nothing was discarded.');
        ContentVersion version = new ContentVersion(Title = 'Atlas ' + name, PathOnClient = name,
            VersionData = Blob.valueOf(content), FirstPublishLocationId = parentId);
        insert as user version;
        return version.Id;
    }

    static void linkFile(Id versionId, Set<Id> ids) {
        Id document = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :versionId WITH USER_MODE].ContentDocumentId;
        List<ContentDocumentLink> links = new List<ContentDocumentLink>();
        for (Id ticketId : ids) links.add(new ContentDocumentLink(ContentDocumentId = document, LinkedEntityId = ticketId, ShareType = 'V'));
        insert as user links;
    }

    static void bump(Atlas_Ticket__c r) { r.Import_Revision__c = (r.Import_Revision__c ?? 0) + 1; }

    static void checkVersion(Atlas_Ticket__c r, Object expected) {
        if (r == null) throw new Atlas_Api.AtlasException('This ticket was deleted or is no longer shared with you. Reload; no changes in this chunk were saved.');
        if (expected == null || expected != dto(r, false).version)
            throw new Atlas_Api.AtlasException('This ticket changed. Reload and review before applying; no changes in this chunk were saved.');
    }

    static Map<Id, Atlas_Ticket__c> lockTickets(Set<Id> ids) {
        return new Map<Id, Atlas_Ticket__c>((List<Atlas_Ticket__c>) Database.query(
            'SELECT Description__c, ' + FIELDS + ', Conversation__r.Id, Conversation__r.Mode__c FROM Atlas_Ticket__c WHERE Id IN :ids FOR UPDATE', AccessLevel.USER_MODE));
    }

    static void storePending(Atlas_Ticket__c r, List<Object> items) {
        String text = JSON.serialize(items);
        r.Pending_Updates__c = text.length() <= MAX_PENDING_CHARS ? text
            : JSON.serialize(new Map<String, Object>{ 'file' => file('atlas-update-history.json', text, r.Id) });
        Map<String, Object> p = planning(r);
        Integer count = 0;
        for (Object item : items) if (((Map<String, Object>) item).get('status') == 'pending') count++;
        p.put('pendingCount', count);
        r.Planning__c = JSON.serialize(p);
        bump(r);
    }

    static Boolean jiraKey(String key) { return key != null && Pattern.matches('^[A-Z][A-Z0-9_]*-[0-9]+$', key); }

    // ---------------------------------------------------------------- edits from the board

    @AuraEnabled
    public static void saveTicket(String ticketJson) {
        try {
            Map<String, Object> t = (Map<String, Object>) JSON.deserializeUntyped(ticketJson);
            Atlas_Ticket__c r = new Atlas_Ticket__c(Id = (Id) t.get('id'));
            Atlas_Ticket__c prior;
            if (r.Id != null) {
                prior = lockTickets(new Set<Id>{ r.Id }).get(r.Id);
                checkVersion(prior, t.get('expectedVersion'));
                Atlas_Data.assertTicketMutationsAllowed(prior?.Conversation__c, prior?.Conversation__r);
                r.Import_Revision__c = prior.Import_Revision__c;
            }
            bump(r);
            if (t.containsKey('jiraKey') && blankToNull(t.get('jiraKey')) != null) {
                String key = ((String) t.get('jiraKey')).trim().toUpperCase();
                if (!jiraKey(key)) throw new Atlas_Api.AtlasException('Enter a real Jira key.');
                if (prior != null && prior.Project_Key__c != null && key.substringBeforeLast('-') != prior.Project_Key__c.toUpperCase())
                    throw new Atlas_Api.AtlasException('The Jira key must belong to this ticket project.');
                t.put('jiraKey', key);
            }
            if (t.get('stage') == 'Exported') throw new Atlas_Api.AtlasException('Use saveExport so the exact CSV is retained before marking Exported.');
            if (t.containsKey('epicId') && blankToNull(t.get('epicId')) != null) {
                Id parentId = (Id) t.get('epicId');
                Atlas_Ticket__c parent = [SELECT Id, Issue_Type__c FROM Atlas_Ticket__c WHERE Id = :parentId WITH USER_MODE];
                if (parentId == r.Id || parent.Issue_Type__c != 'Epic') throw new Atlas_Api.AtlasException('Select another ticket that is an Epic.');
            }
            if (t.get('planning') instanceof Map<String, Object>) {
                Map<String, Object> p = prior == null ? new Map<String, Object>() : planning(prior);
                Map<String, Object> incoming = (Map<String, Object>) t.get('planning');
                for (String key : new List<String>{ 'lane', 'blockerNote', 'dependencies', 'followUp', 'snooze' })
                    if (incoming.containsKey(key)) p.put(key, incoming.get(key));
                if (p.containsKey('lane') && !new Set<String>{ 'Backlog', 'Next', 'In progress', 'Blocked', 'Done' }.contains((String) p.get('lane')))
                    throw new Atlas_Api.AtlasException('Choose a planning lane.');
                for (String key : new List<String>{ 'followUp', 'snooze' })
                    if (!String.isBlank((String) p.get(key))) Date.valueOf((String) p.get(key));
                if (t.containsKey('epicId') && blankToNull(t.get('epicId')) != null) p.remove('unresolvedEpic');
                if (t.get('reconcileAssignee') == true && t.containsKey('assigneeId')) p.remove('unresolvedAssignee');
                if (t.get('reconcileReporter') == true && t.containsKey('reporterId')) p.remove('unresolvedReporter');
                r.Planning__c = JSON.serialize(p);
            }
            if (t.containsKey('customFields')) {
                Map<String,Object> p = r.Planning__c == null ? (prior == null ? new Map<String,Object>() : planning(prior)) : planning(r);
                p.put('customFields',customValues(t.get('customFields')));
                r.Planning__c = JSON.serialize(p);
            }
            Map<String, String> fields = new Map<String, String>{
                'summary' => 'Summary__c', 'description' => 'Description__c', 'issueType' => 'Issue_Type__c', 'epicName' => 'Epic_Name__c',
                'jiraKey' => 'Jira_Key__c', 'jiraStatus' => 'Jira_Status__c',
                'statusCategory' => 'Jira_Status_Category__c', 'priority' => 'Priority__c', 'dueDateSource' => 'Due_Date_Source__c',
                'dueDateNote' => 'Due_Date_Note__c', 'dependsOn' => 'Depends_On__c', 'projectKey' => 'Project_Key__c'
            };
            for (String key : fields.keySet()) {
                if (t.containsKey(key)) r.put(fields.get(key), blankToNull(t.get(key)));
            }
            if (t.containsKey('assigneeId')) r.Assignee__c = (Id) blankToNull(t.get('assigneeId'));
            if (t.containsKey('reporterId')) r.Reporter__c = (Id) blankToNull(t.get('reporterId'));
            Set<Id> people = new Set<Id>();
            if (r.Assignee__c != null && r.Assignee__c != prior?.Assignee__c) people.add(r.Assignee__c);
            if (r.Reporter__c != null && r.Reporter__c != prior?.Reporter__c) people.add(r.Reporter__c);
            Atlas_Identity.versions(people);
            if (t.containsKey('epicId') || t.containsKey('epicKey')) {
                r.Epic__c = (Id) blankToNull(t.get('epicId'));
                r.Epic_Key__c = r.Epic__c == null ? (String) blankToNull(t.get('epicKey')) : null;
            }
            if (t.containsKey('dueDate')) r.Due_Date__c = t.get('dueDate') == null || t.get('dueDate') == '' ? null : Date.valueOf((String) t.get('dueDate'));
            if (t.containsKey('stage')) writeStage(r, prior, (String) t.get('stage'), t.containsKey('jiraKey') ? r.Jira_Key__c : prior?.Jira_Key__c);
            if (r.Jira_Key__c != null && t.containsKey('jiraKey') && r.Stage__c == null) r.Stage__c = 'In Jira';
            upsert as user r;
        } catch (Exception e) {
            throw Atlas_Api.fail(e);
        }
    }

    static Object blankToNull(Object value) {
        return value instanceof String && String.isBlank((String) value) ? null : value;
    }

    static void writeStage(Atlas_Ticket__c r, Atlas_Ticket__c prior, String requested, String effectiveJiraKey) {
        Map<String,Object> p = r.Planning__c == null ? (prior == null ? new Map<String,Object>() : planning(prior)) : planning(r);
        String previous = prior?.Stage__c;
        Boolean wasExported = previous == 'Exported' || prior?.Exported_At__c != null || prior?.Export_Batch__c != null;
        if (requested == 'Archived') {
            if (previous != 'Archived') p.put('preArchiveStage', previous ?? 'Draft');
        } else if (previous == 'Archived') {
            requested = effectiveJiraKey != null ? 'In Jira'
                : wasExported || p.get('preArchiveStage') == 'Exported' ? 'Exported'
                : p.get('preArchiveStage') == 'In Jira' ? 'In Jira' : 'Draft';
            p.remove('preArchiveStage');
        } else if (requested == 'Draft' && wasExported) requested = 'Exported';
        r.Stage__c = requested;
        r.Planning__c = JSON.serialize(p);
    }

    @AuraEnabled
    public static void setStage(List<Id> ticketIds, String stage, String batch, String versionsJson) {
        try {
            if (!new Set<String>{ 'Draft', 'In Jira', 'Archived' }.contains(stage))
                throw new Atlas_Api.AtlasException('Use saveExport to mark an exact saved CSV as Exported.');
            if (ticketIds.size() > 100) throw new Atlas_Api.AtlasException('Use chunks of at most 100 tickets.');
            Map<String, Object> versions = (Map<String, Object>) JSON.deserializeUntyped(versionsJson);
            Map<Id, Atlas_Ticket__c> records = lockTickets(new Set<Id>(ticketIds));
            Set<Id> conversations = new Set<Id>();
            for (Atlas_Ticket__c row : records.values()) if (row.Conversation__c != null) conversations.add(row.Conversation__c);
            Atlas_Data.assertTicketMutationsAllowed(conversations);
            for (Id ticketId : ticketIds) {
                Atlas_Ticket__c r = records.get(ticketId);
                checkVersion(r, versions.get(ticketId));
                writeStage(r, r, stage, r.Jira_Key__c);
                bump(r);
            }
            update as user records.values();
        } catch (Exception e) { throw Atlas_Api.fail(e); }
    }

    static String savedExport(String title) {
        Id owner = UserInfo.getUserId();
        List<ContentVersion> receipts = [SELECT Id, VersionData FROM ContentVersion
            WHERE Title = :title AND CreatedById = :owner WITH USER_MODE LIMIT 1];
        if (receipts.isEmpty()) return null;
        Map<String,Object> data = (Map<String,Object>)JSON.deserializeUntyped(receipts[0].VersionData.toString());
        return JSON.serialize(new Map<String,Object>{'fileId' => data.get('csvFileId'), 'receiptId' => receipts[0].Id,
            'count' => ((Map<String,Object>)data.get('versions')).size()});
    }

    /** Saves the exact reviewed CSV and immutable receipt before exposing a download. */
    @AuraEnabled
    public static String saveExport(String exportJson) {
        Savepoint sp = Database.setSavepoint();
        try {
            String receiptTitle = 'Atlas atlas-export-' + Atlas_Api.sha256(Blob.valueOf(UserInfo.getUserId() + ':' + exportJson));
            String replay = savedExport(receiptTitle);
            if (replay != null) return replay;
            Map<String, Object> input = (Map<String, Object>) JSON.deserializeUntyped(exportJson);
            Map<String, Object> versions = (Map<String, Object>) input.get('versions');
            if (versions == null || versions.isEmpty() || versions.size() > 100) throw new Atlas_Api.AtlasException('Export 1–100 reviewed tickets per file.');
            Set<Id> ids = new Set<Id>();
            for (String key : versions.keySet()) ids.add((Id) key);
            Map<Id, Atlas_Ticket__c> records = lockTickets(ids);
            Set<Id> conversations = new Set<Id>();
            for (Atlas_Ticket__c row : records.values()) if (row.Conversation__c != null) conversations.add(row.Conversation__c);
            Atlas_Data.assertTicketMutationsAllowed(conversations);
            replay = savedExport(receiptTitle);
            if (replay != null) return replay;
            String phase = (String) input.get('phase');
            if (phase != 'snapshot') {
                Set<String> liveKeys=new Set<String>();
                for (Id ticketId : ids) liveKeys.add(Atlas_JiraReservations.key(ticketId,'create',null));
                Atlas_JiraReservations.assertManualAllowed(liveKeys);
                Set<Id> people = new Set<Id>();
                for (Atlas_Ticket__c row : records.values()) {
                    if (row.Assignee__c != null) people.add(row.Assignee__c);
                    if (row.Reporter__c != null) people.add(row.Reporter__c);
                }
                Atlas_Identity.versions(people);
                Map<String,Object> jiraIds = (Map<String,Object>)input.get('jiraIds');
                for (Atlas_Person__c person : [SELECT Id, Jira_Account_Id__c FROM Atlas_Person__c WHERE Id IN :people WITH USER_MODE])
                    if (jiraIds == null || jiraIds.get(person.Id) != (person.Jira_Account_Id__c ?? ''))
                        throw new Atlas_Api.AtlasException('A Jira identity changed since CSV preparation. Reload Team & Jira and prepare the export again.');
            }
            Set<Id> parentIds = new Set<Id>();
            Set<String> parentKeys = new Set<String>();
            for (Atlas_Ticket__c r : records.values()) {
                if (r.Epic__c != null) parentIds.add(r.Epic__c);
                if (r.Epic_Key__c != null) parentKeys.add(r.Epic_Key__c);
            }
            Map<Id, Atlas_Ticket__c> parents = new Map<Id, Atlas_Ticket__c>([SELECT Id, Issue_Type__c, Jira_Key__c, Project_Key__c, Stage__c
                FROM Atlas_Ticket__c WHERE Id IN :parentIds OR Jira_Key__c IN :parentKeys WITH USER_MODE FOR UPDATE]);
            Map<String, Atlas_Ticket__c> parentsByKey = new Map<String, Atlas_Ticket__c>();
            for (Atlas_Ticket__c p : parents.values()) parentsByKey.put(p.Jira_Key__c, p);
            for (Id ticketId : ids) {
                Atlas_Ticket__c r = records.get(ticketId);
                checkVersion(r, versions.get(ticketId));
                if (phase != 'snapshot') {
                    if (r.Stage__c != 'Draft' || r.Jira_Key__c != null || r.Exported_At__c != null || r.Export_Batch__c != null) throw new Atlas_Api.AtlasException('Only uncreated Draft tickets can be exported for creation. Re-download old exports from history; do not create Jira duplicates.');
                    if ((phase == 'epics') != (r.Issue_Type__c == 'Epic')) throw new Atlas_Api.AtlasException('Export epics first, separately from children.');
                    if (phase != 'epics' && phase != 'children') throw new Atlas_Api.AtlasException('Choose epics or children export.');
                    Map<String, Object> p = planning(r);
                    if (p.get('unresolvedAssignee') != null || p.get('unresolvedReporter') != null || p.get('unresolvedEpic') != null)
                        throw new Atlas_Api.AtlasException('Reconcile unresolved identities and parents before export.');
                    if (r.Issue_Type__c != 'Epic' && (r.Epic__c != null || r.Epic_Key__c != null)) {
                        Atlas_Ticket__c parent = r.Epic__c == null ? parentsByKey.get(r.Epic_Key__c) : parents.get(r.Epic__c);
                        if (parent == null || parent.Issue_Type__c != 'Epic' || !jiraKey(parent.Jira_Key__c) || parent.Stage__c == 'Archived'
                            || (r.Project_Key__c != null && parent.Jira_Key__c.substringBeforeLast('-') != r.Project_Key__c.toUpperCase()))
                            throw new Atlas_Api.AtlasException('Unresolved parent: import or manually confirm its same-project Epic Jira key first.');
                        Map<String, Object> exportedParents = (Map<String, Object>) input.get('parentKeys');
                        if (exportedParents == null || exportedParents.get(ticketId) != parent.Jira_Key__c)
                            throw new Atlas_Api.AtlasException('Epic key changed since CSV preparation. Prepare the export again.');
                    }
                }
            }
            String csv = (String) input.get('csv');
            if (String.isBlank(csv)) throw new Atlas_Api.AtlasException('The exact CSV is required.');
            Id csvId = file('atlas-' + phase + '.csv', csv, null);
            input.remove('csv');
            input.put('csvFileId', csvId);
            input.put('at', Datetime.now());
            input.put('by', UserInfo.getName());
            Id receiptId = file(receiptTitle.removeStart('Atlas '), JSON.serialize(input), null);
            linkFile(csvId, ids);
            linkFile(receiptId, ids);
            for (Atlas_Ticket__c r : records.values()) {
                Map<String, Object> p = planning(r);
                // The linked receipt chain preserves all exports without an ever-growing field.
                p.put('latestExportReceipt', receiptId);
                r.Planning__c = JSON.serialize(p);
                r.Export_File__c = csvId;
                if (phase != 'snapshot') {
                    r.Stage__c = 'Exported'; r.Exported_At__c = Datetime.now(); r.Export_Batch__c = (String) input.get('batch');
                }
                bump(r);
            }
            update as user records.values();
            return JSON.serialize(new Map<String, Object>{ 'fileId' => csvId, 'receiptId' => receiptId, 'count' => ids.size() });
        } catch (Exception e) { Database.rollback(sp); throw Atlas_Api.fail(e); }
    }

    // ---------------------------------------------------------------- agent batches

    /**
     * Saves a reviewed atlas-tickets batch. The component has already resolved aliases to
     * person IDs and converted descriptions to Jira text. Re-sending the same ref in the
     * same conversation revises the draft instead of creating a duplicate.
     */
    static Set<Id> batchPeople(Map<String,Object> batch) {
        Set<Id> ids = new Set<Id>();
        for (String groupName : new List<String>{'epics','tickets','updates'}) for (Object raw : (List<Object>)(batch.get(groupName) ?? new List<Object>())) {
            Map<String,Object> item = (Map<String,Object>)raw;
            if (groupName == 'updates') item = (Map<String,Object>)(item.get('changes') ?? new Map<String,Object>());
            for (String key : new List<String>{'assigneeId','reporterId'}) if (blankToNull(item.get(key)) != null) ids.add((Id)item.get(key));
        }
        return ids;
    }

    /** Support Tickets can draft a manager-reviewed bug, never change existing Jira work. */
    static void checkInvestigationBatch(Id conversationId, Map<String,Object> batch, Atlas_Conversation__c savedConversation) {
        if (conversationId != null && savedConversation == null) {
            List<Atlas_Conversation__c> rows = [SELECT Id, Mode__c FROM Atlas_Conversation__c WHERE Id = :conversationId WITH USER_MODE];
            if (rows.isEmpty()) throw new Atlas_Api.AtlasException(
                'Atlas could not verify the saved mode for this conversation. Nothing was changed.');
            savedConversation = rows[0];
        }
        Atlas_Data.assertTicketMutationsAllowed(conversationId, savedConversation);
        if (savedConversation?.Mode__c != 'support-tickets') return;
        for (String groupName : new List<String>{'epics', 'updates'}) {
            if (batch.get(groupName) != null && (!(batch.get(groupName) instanceof List<Object>) || !((List<Object>)batch.get(groupName)).isEmpty()))
                throw new Atlas_Api.AtlasException('Support Tickets can only prepare one Bug for manager review, not epics or ticket updates.');
        }
        List<Object> tickets = (List<Object>)batch.get('tickets');
        if (tickets == null || tickets.size() != 1) throw new Atlas_Api.AtlasException('Support Tickets needs exactly one Bug draft for manager review.');
        Map<String,Object> ticket = (Map<String,Object>)tickets[0];
        Set<String> allowed = new Set<String>{'ref', 'issueType', 'summary', 'description', 'priority', 'assigneeId', 'dueDate'};
        for (String field : ticket.keySet()) if (!allowed.contains(field))
            throw new Atlas_Api.AtlasException('Support Tickets does not support the Bug field ' + field + '.');
        if (ticket.get('issueType') != 'Bug' || String.isBlank((String)ticket.get('ref'))
            || String.isBlank((String)ticket.get('summary')) || String.isBlank((String)ticket.get('description')))
            throw new Atlas_Api.AtlasException('The manager-review Bug needs a reference, summary and evidence in its description.');
        List<Atlas_Setting__c> settings = [SELECT Data__c FROM Atlas_Setting__c WHERE Key__c = 'jira' WITH USER_MODE LIMIT 1];
        Map<String,Object> jira = settings.isEmpty() || String.isBlank(settings[0].Data__c)
            ? new Map<String,Object>() : (Map<String,Object>)JSON.deserializeUntyped(settings[0].Data__c);
        String project = (String)jira.get('projectKey');
        if (String.isBlank(project) || project != batch.get('projectKey'))
            throw new Atlas_Api.AtlasException('Use the project saved in Jira settings for manager review. Reload the review if those settings changed.');
        Map<String,Object> manager = Atlas_Jira.reviewManager();
        String assignee = (String)blankToNull(ticket.get('assigneeId'));
        String expected = manager.get('ready') == true ? (String)manager.get('personId') : null;
        if (assignee != expected) throw new Atlas_Api.AtlasException('Assign this Bug only to the configured manager for triage, or leave it unassigned when the manager is not ready. Reopen the review after changing Jira settings.');
        String origin = conversationId + ':' + ticket.get('ref');
        for (Atlas_Ticket__c existing : [SELECT Issue_Type__c, Stage__c FROM Atlas_Ticket__c WHERE Origin_Key__c = :origin WITH USER_MODE]) {
            if (existing.Issue_Type__c != 'Bug' || existing.Stage__c != 'Draft')
                throw new Atlas_Api.AtlasException('Support Tickets can revise only its unexported Bug drafts. Use a new reference for a new bug.');
        }
    }

    /** Capture versions when the human opens the review, not later when they press Save. */
    @AuraEnabled
    public static String prepareBatch(Id conversationId, String batchJson) {
        try {
            Map<String,Object> batch = (Map<String,Object>)JSON.deserializeUntyped(batchJson);
            checkInvestigationBatch(conversationId, batch, null);
            Set<String> origins = new Set<String>(), targets = new Set<String>();
            Map<String,Object> versions = new Map<String,Object>();
            for (String groupName : new List<String>{'epics','tickets'}) for (Object raw : (List<Object>)(batch.get(groupName) ?? new List<Object>())) {
                String origin = conversationId + ':' + ((Map<String,Object>)raw).get('ref');
                origins.add(origin); versions.put(origin, 'new');
            }
            for (Object raw : (List<Object>)(batch.get('updates') ?? new List<Object>())) targets.add(String.valueOf(((Map<String,Object>)raw).get('target')).toUpperCase());
            for (Atlas_Ticket__c r : Database.query('SELECT Origin_Key__c, ' + FIELDS + ' FROM Atlas_Ticket__c WHERE Origin_Key__c IN :origins OR Name IN :targets OR Jira_Key__c IN :targets', AccessLevel.USER_MODE)) {
                String version = dto(r,false).version;
                if (origins.contains(r.Origin_Key__c)) versions.put(r.Origin_Key__c,version);
                if (targets.contains(r.Name.toUpperCase())) versions.put(r.Name.toUpperCase(),version);
                if (r.Jira_Key__c != null && targets.contains(r.Jira_Key__c.toUpperCase())) versions.put(r.Jira_Key__c.toUpperCase(),version);
            }
            batch.put('expectedVersions',versions);
            batch.put('expectedIdentityVersions',Atlas_Identity.versions(batchPeople(batch)));
            return JSON.serialize(batch);
        } catch (Exception e) { throw Atlas_Api.fail(e); }
    }

    @AuraEnabled
    public static String applyBatch(Id conversationId, String batchJson) {
        Savepoint sp = Database.setSavepoint();
        try {
            Map<String, Object> batch = (Map<String, Object>) JSON.deserializeUntyped(batchJson);
            if (conversationId == null) throw new Atlas_Api.AtlasException('A conversation is required for a stable batch identity.');
            Atlas_Conversation__c serial = [SELECT Id, Mode__c FROM Atlas_Conversation__c WHERE Id = :conversationId WITH USER_MODE FOR UPDATE];
            Atlas_Data.assertTicketMutationsAllowed(conversationId, serial);
            Map<String,Object> receiptInput = batch.clone();
            receiptInput.remove('expectedVersions');
            receiptInput.remove('expectedIdentityVersions');
            String digest = Atlas_Api.sha256(Blob.valueOf(JSON.serialize(receiptInput)));
            String batchKey = 'Atlas atlas-batch-' + Atlas_Api.sha256(Blob.valueOf(String.valueOf(batch.get('batchId') ?? digest)));
            List<ContentVersion> receipts = [SELECT Id, VersionData, Description FROM ContentVersion WHERE FirstPublishLocationId = :conversationId AND Title = :batchKey WITH USER_MODE LIMIT 1];
            if (!receipts.isEmpty()) {
                if (receipts[0].Description != digest) throw new Atlas_Api.AtlasException('This batchId already belongs to different content. Use a new batchId.');
                return batchHandoff(conversationId, receipts[0]);
            }
            checkInvestigationBatch(conversationId, batch, serial);
            Map<String,Object> identityVersions = Atlas_Identity.versions(batchPeople(batch));
            Map<String,Object> expectedIdentities = (Map<String,Object>)batch.get('expectedIdentityVersions');
            if (!identityVersions.isEmpty() && (expectedIdentities == null || identityVersions != expectedIdentities))
                throw new Atlas_Api.AtlasException('A Salesforce/Jira identity changed. Reopen the ticket review before saving.');
            List<Object> epics = (List<Object>) (batch.get('epics') ?? new List<Object>());
            List<Object> tickets = (List<Object>) (batch.get('tickets') ?? new List<Object>());
            List<Object> updates = (List<Object>) (batch.get('updates') ?? new List<Object>());
            String project = (String) batch.get('projectKey');
            if (epics.size() + tickets.size() + updates.size() > 50) throw new Atlas_Api.AtlasException('Use batches of at most 50 items.');

            Set<String> origins = new Set<String>();
            for (Object item : epics) origins.add(conversationId + ':' + ((Map<String, Object>) item).get('ref'));
            for (Object item : tickets) origins.add(conversationId + ':' + ((Map<String, Object>) item).get('ref'));
            Map<String,Object> versions = (Map<String,Object>)batch.get('expectedVersions');
            if (versions == null) throw new Atlas_Api.AtlasException('Reopen this ticket review to capture current versions before saving.');
            Map<String, Atlas_Ticket__c> existing = new Map<String, Atlas_Ticket__c>();
            Set<Id> existingConversations = new Set<Id>();
            for (Atlas_Ticket__c r : Database.query('SELECT Origin_Key__c, ' + FIELDS + ' FROM Atlas_Ticket__c WHERE Origin_Key__c IN :origins FOR UPDATE', AccessLevel.USER_MODE)) {
                checkVersion(r, versions.get(r.Origin_Key__c));
                existing.put(r.Origin_Key__c, r);
                if (r.Conversation__c != null) existingConversations.add(r.Conversation__c);
            }
            Atlas_Data.assertTicketMutationsAllowed(existingConversations);
            for (String origin : origins) if (!existing.containsKey(origin) && versions.get(origin) != 'new') throw new Atlas_Api.AtlasException('A reviewed draft no longer exists; reload the review.');

            List<Map<String, Object>> saved = new List<Map<String, Object>>();
            Map<String, Id> refs = new Map<String, Id>();
            List<Atlas_Ticket__c> epicRecords = new List<Atlas_Ticket__c>();
            for (Object item : epics) epicRecords.add(record((Map<String, Object>) item, conversationId, project, 'Epic', existing));
            upsert as user epicRecords;
            for (Integer i = 0; i < epics.size(); i++) refs.put((String) ((Map<String, Object>) epics[i]).get('ref'), epicRecords[i].Id);

            Map<String, Atlas_Ticket__c> epicLinks = epicLinks(tickets);
            List<Atlas_Ticket__c> taskRecords = new List<Atlas_Ticket__c>();
            for (Object item : tickets) {
                Map<String, Object> t = (Map<String, Object>) item;
                Atlas_Ticket__c r = record(t, conversationId, project, (String) (t.get('issueType') ?? 'Task'), existing);
                // A revised draft is a complete proposal, not a patch. Clear both parent
                // representations before applying the reviewed choice.
                r.Epic__c = null;
                r.Epic_Key__c = null;
                if (t.get('epicRef') != null) {
                    r.Epic__c = refs.get((String) t.get('epicRef'));
                    if (r.Epic__c == null) throw new Atlas_Api.AtlasException('Ticket ' + t.get('ref') + ' uses epicRef "' + t.get('epicRef') + '", which is not an epic in the same message.');
                } else if (t.get('epicTicket') != null || t.get('epicKey') != null) {
                    Atlas_Ticket__c epic = epicLinks.get(String.valueOf(t.get('epicTicket') ?? t.get('epicKey')).toUpperCase());
                    if (epic != null) r.Epic__c = epic.Id;
                    else if (t.get('epicTicket') != null) throw new Atlas_Api.AtlasException('No epic ticket ' + t.get('epicTicket') + ' exists.');
                    r.Epic_Key__c = (String) t.get('epicKey');
                }
                taskRecords.add(r);
            }
            upsert as user taskRecords;
            for (Integer i = 0; i < epics.size(); i++) saved.add(savedRow((Map<String, Object>) epics[i], epicRecords[i]));
            for (Integer i = 0; i < tickets.size(); i++) saved.add(savedRow((Map<String, Object>) tickets[i], taskRecords[i]));

            List<Map<String, Object>> queued = queueUpdates(updates, conversationId, versions);

            Set<Id> ids = new Set<Id>();
            for (Atlas_Ticket__c r : epicRecords) ids.add(r.Id);
            for (Atlas_Ticket__c r : taskRecords) ids.add(r.Id);
            Map<Id, Atlas_Ticket__c> names = new Map<Id, Atlas_Ticket__c>([SELECT Id, Name FROM Atlas_Ticket__c WHERE Id IN :ids WITH USER_MODE]);
            for (Map<String, Object> row : saved) row.put('atlasId', names.get((Id) row.get('id')).Name);
            String response = JSON.serialize(new Map<String, Object>{ 'saved' => saved, 'updates' => queued });
            ContentVersion receipt = new ContentVersion(Title = batchKey, PathOnClient = 'batch-receipt.json', VersionData = Blob.valueOf(response),
                Description = digest, FirstPublishLocationId = conversationId);
            insert as user receipt;
            return batchHandoff(conversationId, receipt);
        } catch (Exception e) {
            Database.rollback(sp);
            throw Atlas_Api.fail(e);
        }
    }

    /** The conversation lock serializes handoffs by immutable business receipt Id.
     * Older receipt-only batches can acquire a handoff without rewriting tickets or
     * their receipt. Any failed message/File write rolls back the whole batch. */
    static String batchHandoff(Id conversationId, ContentVersion receipt) {
        String title = 'Atlas atlas-batch-handoff-' + receipt.Id;
        List<ContentVersion> prior = [SELECT VersionData FROM ContentVersion
            WHERE FirstPublishLocationId = :conversationId AND Title = :title WITH USER_MODE LIMIT 1];
        if (!prior.isEmpty()) return prior[0].VersionData.toString();
        Map<String,Object> response = (Map<String,Object>)JSON.deserializeUntyped(receipt.VersionData.toString());
        List<String> lines = new List<String>{'TICKETS SAVED in Atlas as drafts. My team can see them; I export them to Jira myself.'};
        if (Atlas_Data.isSupportTicketsConversation(conversationId)) lines.add(
            'This is a suspected bug for manager review and assignment, not a repair instruction. Nothing was sent to Jira. Before exporting, confirm the review manager; an unassigned draft must be routed to the manager manually.');
        for (Object raw : (List<Object>)response.get('saved')) {
            Map<String,Object> row = (Map<String,Object>)raw;
            lines.add('- ' + row.get('ref') + ' → ' + row.get('atlasId') + ' (' + row.get('issueType') + ') "' + row.get('summary') + '" [ticket ' + row.get('id') + ']');
        }
        List<Object> updates = (List<Object>)response.get('updates');
        if (!updates.isEmpty()) lines.add('Updates:');
        for (Object raw : updates) {
            Map<String,Object> row = (Map<String,Object>)raw;
            lines.add('- ' + row.get('target') + ' → ' + row.get('ticket') + ': queued for me to copy into Jira [update ' + row.get('updateId') + ']');
        }
        lines.add('Batch receipt: ' + receipt.Id);
        lines.add('To change a draft, resend it with the same ref. For more tickets, send another atlas-tickets with new refs.');
        lines.add('\nREMINDER: each response must be at most 14,000 characters. Split larger replies into separate responses.');
        String acknowledgment = String.join(lines, '\n');
        Atlas_Data.addMessage(conversationId, 'To Agent', 'tickets', acknowledgment);
        response.put('receiptId', receipt.Id);
        response.put('acknowledgment', acknowledgment);
        String text = JSON.serialize(response);
        file(title.removeStart('Atlas '), text, conversationId);
        return text;
    }

    static Atlas_Ticket__c record(Map<String, Object> t, Id conversationId, String project, String issueType, Map<String, Atlas_Ticket__c> existing) {
        String origin = conversationId + ':' + t.get('ref');
        Atlas_Ticket__c prior = existing.get(origin);
        if (prior != null && prior.Stage__c != 'Draft') {
            throw new Atlas_Api.AtlasException(t.get('ref') + ' was already saved as ' + prior.Name + ' and has left Draft (it is ' + prior.Stage__c
                + '). Use a new ref for new tickets, or send an update with "target":"' + prior.Name + '" to change it.');
        }
        String dueDate = (String) t.get('dueDate');
        Map<String,Object> p = prior == null ? new Map<String,Object>() : planning(prior);
        if (t.containsKey('customFields')) p.put('customFields',customValues(t.get('customFields')));
        return new Atlas_Ticket__c(
            Planning__c = JSON.serialize(p),
            Id = prior?.Id,
            Import_Revision__c = (prior?.Import_Revision__c ?? 0) + 1,
            Origin_Key__c = origin,
            Conversation__c = conversationId,
            Summary__c = (String) t.get('summary'),
            Description__c = (String) t.get('description'),
            Issue_Type__c = issueType,
            Epic_Name__c = issueType == 'Epic' ? (String) (t.get('epicName') ?? t.get('summary')) : null,
            Project_Key__c = project,
            Stage__c = 'Draft',
            Priority__c = (String) t.get('priority'),
            Due_Date__c = String.isBlank(dueDate) ? null : Date.valueOf(dueDate),
            Due_Date_Source__c = (String) t.get('dueDateSource'),
            Due_Date_Note__c = (String) t.get('dueDateNote'),
            Depends_On__c = (String) t.get('dependsOn'),
            Assignee__c = (Id) t.get('assigneeId'),
            Reporter__c = (Id) t.get('reporterId')
        );
    }

    static Map<String, Object> savedRow(Map<String, Object> input, Atlas_Ticket__c r) {
        return new Map<String, Object>{ 'ref' => input.get('ref'), 'id' => r.Id, 'summary' => r.Summary__c, 'issueType' => r.Issue_Type__c };
    }

    /** Existing epics referenced by TKT ID or Jira key. */
    static Map<String, Atlas_Ticket__c> epicLinks(List<Object> tickets) {
        Set<String> wanted = new Set<String>();
        for (Object item : tickets) {
            Map<String, Object> t = (Map<String, Object>) item;
            if (t.get('epicTicket') != null) wanted.add(String.valueOf(t.get('epicTicket')).toUpperCase());
            if (t.get('epicKey') != null) wanted.add(String.valueOf(t.get('epicKey')).toUpperCase());
        }
        Map<String, Atlas_Ticket__c> result = new Map<String, Atlas_Ticket__c>();
        if (wanted.isEmpty()) return result;
        for (Atlas_Ticket__c r : [SELECT Id, Name, Jira_Key__c FROM Atlas_Ticket__c WHERE Issue_Type__c = 'Epic' AND (Name IN :wanted OR Jira_Key__c IN :wanted) WITH USER_MODE]) {
            result.put(r.Name.toUpperCase(), r);
            if (r.Jira_Key__c != null) result.put(r.Jira_Key__c.toUpperCase(), r);
        }
        return result;
    }

    /** Updates to existing tickets wait on the ticket until someone applies them in Jira. */
    static List<Map<String, Object>> queueUpdates(List<Object> updates, Id conversationId, Map<String,Object> versions) {
        List<Map<String, Object>> queued = new List<Map<String, Object>>();
        if (updates.isEmpty()) return queued;
        Set<String> targets = new Set<String>();
        for (Object item : updates) targets.add(String.valueOf(((Map<String, Object>) item).get('target')).toUpperCase());
        Map<String, Atlas_Ticket__c> byTarget = new Map<String, Atlas_Ticket__c>();
        for (Atlas_Ticket__c r : Database.query('SELECT Description__c, ' + FIELDS + ', Conversation__r.Id, Conversation__r.Mode__c FROM Atlas_Ticket__c WHERE Name IN :targets OR Jira_Key__c IN :targets FOR UPDATE', AccessLevel.USER_MODE)) {
            Atlas_Data.assertTicketMutationsAllowed(r.Conversation__c, r.Conversation__r);
            byTarget.put(r.Name.toUpperCase(), r);
            if (r.Jira_Key__c != null) byTarget.put(r.Jira_Key__c.toUpperCase(), r);
        }
        Map<Id, Atlas_Ticket__c> changed = new Map<Id, Atlas_Ticket__c>();
        Integer n = 0;
        for (Object item : updates) {
            Map<String, Object> u = (Map<String, Object>) item;
            String target = String.valueOf(u.get('target')).toUpperCase();
            Atlas_Ticket__c r = changed.get(byTarget.get(target)?.Id) ?? byTarget.get(target);
            if (r == null) throw new Atlas_Api.AtlasException('No ticket ' + u.get('target') + ' exists in Atlas. Ask for tickets first.');
            if (!changed.containsKey(r.Id)) checkVersion(r, versions.get(target));
            List<Object> items = pending(r);
            String id = 'U' + Datetime.now().getTime() + '-' + (n++);
            Map<String, Object> changes = u.get('changes') instanceof Map<String, Object> ? (Map<String, Object>) u.get('changes') : new Map<String, Object>();
            Object assigneeLabel = changes.remove('assignee');
            if (assigneeLabel != null && !changes.containsKey('assigneeId')) throw new Atlas_Api.AtlasException('Resolve assignee to a saved person before queuing.');
            Map<String,Object> custom = customValues(changes.remove('customFields'));
            for (String key : custom.keySet()) changes.put('custom:' + key, custom.get(key));
            Map<String, Object> baseline = new Map<String, Object>();
            for (String key : changes.keySet()) {
                if (!UPDATE_FIELDS.containsKey(key) && !key.startsWith('custom:')) throw new Atlas_Api.AtlasException('Unsupported Jira field: ' + key);
                if (key.startsWith('custom:')) customValues(new Map<String,Object>{key.substring(7)=>changes.get(key)});
                baseline.put(key, updateValue(r,key));
            }
            List<Object> comments = new List<Object>();
            Object input = u.get('comments');
            List<Object> rows = input instanceof List<Object> ? (List<Object>) input : input == null ? new List<Object>() : new List<Object>{ input };
            for (Object comment : rows) {
                Map<String, Object> c = comment instanceof Map<String, Object> ? (Map<String, Object>) comment : new Map<String, Object>{ 'text' => comment };
                c.put('status', 'pending');
                comments.add(c);
            }
            items.add(new Map<String, Object>{
                'id' => id, 'status' => 'pending', 'created' => Datetime.now(), 'createdBy' => UserInfo.getName(),
                'conversation' => conversationId, 'changes' => changes, 'comments' => comments, 'reason' => u.get('reason'),
                'baseline' => baseline, 'assigneeLabel' => assigneeLabel, 'baseRevision' => r.Import_Revision__c, 'fieldStatus' => new Map<String, Object>()
            });
            storePending(r, items);
            changed.put(r.Id, r);
            queued.add(new Map<String, Object>{ 'target' => u.get('target'), 'ticket' => r.Name, 'jiraKey' => r.Jira_Key__c, 'updateId' => id });
        }
        update as user changed.values();
        return queued;
    }

    static Map<String,Object> customValues(Object value) {
        if (value == null) return new Map<String,Object>();
        if (!(value instanceof Map<String,Object>)) throw new Atlas_Api.AtlasException('customFields must be an object of exact Jira field names to text or null.');
        Map<String,Object> fields = (Map<String,Object>)value;
        for (String key : fields.keySet()) {
            if (String.isBlank(key) || key.length() > 255 || (fields.get(key) != null && !(fields.get(key) instanceof String)))
                throw new Atlas_Api.AtlasException('Custom fields need nonempty names up to 255 characters and text or null values.');
        }
        return fields;
    }

    static Object updateValue(Atlas_Ticket__c r, String key) {
        if (key == 'epicKey') return new Map<String,Object>{'epicId'=>r.Epic__c, 'rawKey'=>r.Epic_Key__c,
            'effectiveKey'=>r.Epic__r?.Jira_Key__c ?? r.Epic_Key__c};
        return key.startsWith('custom:') ? customValues(planning(r).get('customFields')).get(key.substring(7)) : r.get(UPDATE_FIELDS.get(key));
    }

    /** Apex == ignores letter case in text, so a summary changed only in case since the proposal would not count as a conflict. */
    @TestVisible
    static Boolean sameValue(Object a, Object b) {
        if (a instanceof String && b instanceof String) return ((String) a).equals((String) b);
        if (a instanceof Map<String, Object> && b instanceof Map<String, Object>) {
            Map<String, Object> x = (Map<String, Object>) a, y = (Map<String, Object>) b;
            if (x.size() != y.size()) return false;
            for (String k : x.keySet()) if (!y.containsKey(k) || !sameValue(x.get(k), y.get(k))) return false;
            return true;
        }
        return a == b;
    }

    static final Map<String, String> UPDATE_FIELDS = new Map<String, String>{
        'summary' => 'Summary__c', 'description' => 'Description__c', 'priority' => 'Priority__c', 'status' => 'Jira_Status__c',
        'statusCategory' => 'Jira_Status_Category__c', 'assigneeId' => 'Assignee__c', 'epicKey' => 'Epic_Key__c',
        'dueDate' => 'Due_Date__c', 'dueDateNote' => 'Due_Date_Note__c', 'dueDateSource' => 'Due_Date_Source__c'
    };

    /** Completing an entire mixed checklist is unsafe: confirm parts independently. */
    @AuraEnabled
    public static void completeUpdate(Id ticketId, String updateId, Boolean done) {
        if (done == true) throw Atlas_Api.fail(new Atlas_Api.AtlasException('Confirm each field and comment independently using completeUpdatePart.'));
        completeUpdatePart(ticketId, updateId, 'dismiss', false, getTicket(ticketId).version);
    }

    @AuraEnabled
    public static void completeUpdatePart(Id ticketId, String updateId, String part, Boolean done, String expectedVersion) {
        completeUpdatePartInternal(ticketId,updateId,part,done,expectedVersion,false);
    }
    static void completeUpdatePartInternal(Id ticketId, String updateId, String part, Boolean done, String expectedVersion,Boolean liveConfirmed) {
        Savepoint sp = Database.setSavepoint();
        try {
            Atlas_Ticket__c r = lockTickets(new Set<Id>{ ticketId }).get(ticketId);
            if (r == null) throw new Atlas_Api.AtlasException('This ticket was deleted or is no longer shared with you. Reload; nothing was saved.');
            Atlas_Data.assertTicketMutationsAllowed(r.Conversation__c, r.Conversation__r);
            List<Object> items = pending(r);
            Map<String, Object> found;
            for (Object item : items) if (((Map<String, Object>) item).get('id') == updateId) found = (Map<String, Object>) item;
            if (found == null) throw new Atlas_Api.AtlasException('That update no longer exists. Refresh the ticket.');
            if (found.get('status') != 'pending') return;
            checkVersion(r, expectedVersion);
            Map<String, Object> changes = found.get('changes') instanceof Map<String, Object> ? (Map<String, Object>) found.get('changes') : new Map<String, Object>();
            Map<String, Object> states = found.get('fieldStatus') instanceof Map<String, Object> ? (Map<String, Object>) found.get('fieldStatus') : new Map<String, Object>();
            List<Object> comments = found.get('comments') instanceof List<Object> ? (List<Object>) found.get('comments') : new List<Object>();
            if (!liveConfirmed) {
                Set<String> liveKeys=new Set<String>{Atlas_JiraReservations.key(ticketId,part,updateId)};
                if (part=='dismiss') {
                    for (String name : changes.keySet()) liveKeys.add(Atlas_JiraReservations.key(ticketId,'field:'+name,updateId));
                    for (Integer i=0;i<comments.size();i++) liveKeys.add(Atlas_JiraReservations.key(ticketId,'comment:'+i,updateId));
                }
                Atlas_JiraReservations.assertManualAllowed(liveKeys);
            }
            if (part == 'dismiss') {
                found.put('status', 'dismissed');
            } else if (part.startsWith('field:')) {
                String key = part.substring(6);
                if (!changes.containsKey(key) || (!UPDATE_FIELDS.containsKey(key) && !key.startsWith('custom:'))) throw new Atlas_Api.AtlasException('Unknown field checklist item.');
                if (states.containsKey(key)) return;
                Map<String, Object> baseline = (Map<String, Object>) found.get('baseline');
                if (done == true && baseline == null) throw new Atlas_Api.AtlasException('This older update has no immutable baseline. Dismiss it and request a fresh proposal.');
                if (done == true && !sameValue(JSON.deserializeUntyped(JSON.serialize(updateValue(r,key))), baseline.get(key)))
                    throw new Atlas_Api.AtlasException('Baseline conflict for ' + key + '. Refresh Jira and request a new proposal; this update was not applied.');
                if (done == true) {
                    Object value = changes.get(key);
                    if (key == 'dueDate') value = String.isBlank((String) value) ? null : Date.valueOf((String) value);
                    if (key.startsWith('custom:')) {
                        Map<String,Object> p = planning(r), custom = customValues(p.get('customFields'));
                        custom.put(key.substring(7),value);
                        p.put('customFields',customValues(custom));
                        r.Planning__c = JSON.serialize(p);
                    } else r.put(UPDATE_FIELDS.get(key), blankToNull(value));
                    if (key == 'epicKey') r.Epic__c = null;
                    // A checklist confirmation advances the mirror, not Jira's source
                    // timestamp. The same (or undated) snapshot cannot undo it.
                    Map<String,Object> confirmed = planning(r);
                    confirmed.put('manualConfirmationBaseline', new Map<String,Object>{'updated'=>r.Jira_Updated__c});
                    r.Planning__c = JSON.serialize(confirmed);
                }
                states.put(key, done == true ? 'done' : 'dismissed');
                found.put('fieldStatus', states);
            } else if (part.startsWith('comment:')) {
                Integer index = Integer.valueOf(part.substring(8));
                if (index < 0 || index >= comments.size()) throw new Atlas_Api.AtlasException('Unknown comment checklist item.');
                Object original = comments[index];
                Map<String, Object> c = original instanceof Map<String, Object> ? (Map<String, Object>) original : new Map<String, Object>{ 'text' => original };
                if (c.get('status') == 'done' || c.get('status') == 'dismissed') return;
                c.put('status', done == true ? 'done' : 'dismissed');
                c.put('closed', Datetime.now()); c.put('closedBy', UserInfo.getName());
                comments[index] = c;
                found.put('comments', comments);
            } else throw new Atlas_Api.AtlasException('Choose one field or one comment.');
            Boolean finished = true;
            for (String key : changes.keySet()) if (!states.containsKey(key)) finished = false;
            for (Object comment : comments) {
                if (!(comment instanceof Map<String, Object>) || !new Set<String>{ 'done', 'dismissed' }.contains((String) ((Map<String, Object>) comment).get('status'))) finished = false;
            }
            if (finished && part != 'dismiss') found.put('status', 'done');
            if (found.get('status') != 'pending') { found.put('closed', Datetime.now()); found.put('closedBy', UserInfo.getName()); }
            List<Object> history = found.get('history') instanceof List<Object> ? (List<Object>) found.get('history') : new List<Object>();
            history.add(new Map<String, Object>{ 'part' => part, 'done' => done, 'at' => Datetime.now(), 'by' => UserInfo.getName() });
            found.put('history', history);
            storePending(r, items);
            update as user r;
        } catch (Exception e) { Database.rollback(sp); throw Atlas_Api.fail(e); }
    }

    // ---------------------------------------------------------------- Jira export import

    /**
     * Applies rows from a Jira CSV export: key, summary, issueType, status, statusCategory,
     * assigneeJiraId, priority, dueDate, epicKey, updated, project. Rows match by Jira key,
     * then exported drafts by summary and issue type. Unmatched rows become new tickets.
     */
    @AuraEnabled
    public static String beginImport(String keysJson) {
        try {
            List<Object> input = (List<Object>) JSON.deserializeUntyped(keysJson);
            if (input.size() > 50000) throw new Atlas_Api.AtlasException('At most 50,000 Jira keys per import.');
            Set<String> keys = new Set<String>();
            for (Object item : input) {
                String key = String.valueOf(item).trim().toUpperCase();
                if (!jiraKey(key) || keys.contains(key)) throw new Atlas_Api.AtlasException('Invalid or duplicate Jira key ' + key + '. No tickets imported.');
                keys.add(key);
            }
            Atlas_Library__c manifest = new Atlas_Library__c(Name='Atlas Jira import', Kind__c='upload', Revision__c=0);
            insert as user manifest;
            manifest.Data_File__c = file('atlas-import-manifest.json', JSON.serialize(keys), manifest.Id);
            update as user manifest;
            return manifest.Data_File__c;
        } catch (Exception e) { throw Atlas_Api.fail(e); }
    }

    @AuraEnabled
    public static String importJira(String rowsJson) {
        Savepoint sp = Database.setSavepoint();
        Map<String, Object> envelope;
        try {
            Object parsed = JSON.deserializeUntyped(rowsJson);
            envelope = parsed instanceof Map<String, Object> ? (Map<String, Object>) parsed : null;
            List<Object> rows = (List<Object>) (envelope == null ? parsed : envelope.get('rows'));
            if (rows.size() > 50) throw new Atlas_Api.AtlasException('Import at most 50 rows per chunk.');
            String receiptTitle;
            String digest = Atlas_Api.sha256(Blob.valueOf(rowsJson));
            if (envelope != null) {
                Id manifestId = (Id) envelope.get('manifestId');
                ContentVersion manifest = [SELECT VersionData, FirstPublishLocationId FROM ContentVersion WHERE Id = :manifestId WITH USER_MODE];
                Atlas_Library__c job = [SELECT Data_File__c, OwnerId, Name FROM Atlas_Library__c WHERE Id = :manifest.FirstPublishLocationId WITH USER_MODE FOR UPDATE];
                if (job.OwnerId != UserInfo.getUserId() || job.Name != 'Atlas Jira import' || job.Data_File__c != manifestId)
                    throw new Atlas_Api.AtlasException('This is not your Jira import manifest.');
                Set<String> allowed = new Set<String>();
                for (Object key : (List<Object>) JSON.deserializeUntyped(manifest.VersionData.toString())) allowed.add((String) key);
                for (Object item : rows) if (!allowed.contains(String.valueOf(((Map<String, Object>) item).get('key')).toUpperCase()))
                    throw new Atlas_Api.AtlasException('Row not in the preflight import manifest.');
                receiptTitle = 'Atlas atlas-import-' + manifestId + '-' + String.valueOf(envelope.get('chunk'));
                List<ContentVersion> previous = [SELECT Id, VersionData, Description FROM ContentVersion WHERE Title = :receiptTitle WITH USER_MODE LIMIT 1];
                if (!previous.isEmpty()) {
                    if (previous[0].Description != digest) throw new Atlas_Api.AtlasException('A completed chunk cannot be retried with different rows. Start a new import.');
                    Map<String, Object> replay = (Map<String, Object>) JSON.deserializeUntyped(previous[0].VersionData.toString());
                    replay.put('receiptId', previous[0].Id);
                    return JSON.serialize(replay);
                }
            }
            Set<String> keys = new Set<String>(), projects = new Set<String>(), summaries = new Set<String>();
            for (Object item : rows) {
                Map<String, Object> row = (Map<String, Object>) item;
                String key = String.valueOf(row.get('key')).trim().toUpperCase();
                if (!jiraKey(key) || keys.contains(key)) throw new Atlas_Api.AtlasException('Invalid or duplicate Jira key ' + key + '. No rows changed.');
                keys.add(key); row.put('key', key);
                String project = key.substringBeforeLast('-');
                if (row.get('project') != null && String.valueOf(row.get('project')).toUpperCase() != project)
                    throw new Atlas_Api.AtlasException('Project does not match Jira key ' + key);
                row.put('project', project); projects.add(project);
                if (row.get('summary') != null) summaries.add((String) row.get('summary'));
            }
            Map<String, Atlas_Ticket__c> byKey = new Map<String, Atlas_Ticket__c>();
            for (Atlas_Ticket__c r : Database.query('SELECT Description__c, ' + FIELDS + ' FROM Atlas_Ticket__c WHERE Jira_Key__c IN :keys FOR UPDATE', AccessLevel.USER_MODE)) byKey.put(r.Jira_Key__c.toUpperCase(), r);
            Map<String, List<Atlas_Ticket__c>> drafts = new Map<String, List<Atlas_Ticket__c>>();
            for (Atlas_Ticket__c r : Database.query('SELECT Description__c, ' + FIELDS + ' FROM Atlas_Ticket__c WHERE Jira_Key__c = null AND Stage__c IN (\'Exported\', \'Draft\') AND Project_Key__c IN :projects AND Summary__c IN :summaries FOR UPDATE', AccessLevel.USER_MODE)) {
                String match = matchKey(r.Project_Key__c, r.Summary__c, r.Issue_Type__c);
                if (!drafts.containsKey(match)) drafts.put(match, new List<Atlas_Ticket__c>());
                drafts.get(match).add(r);
            }
            Map<String, Id> peopleByJira = new Map<String, Id>();
            Set<Id> people = new Set<Id>();
            for (Atlas_Person__c p : [SELECT Id, Jira_Account_Id__c FROM Atlas_Person__c WITH USER_MODE]) {
                people.add(p.Id);
                if (p.Jira_Account_Id__c != null) peopleByJira.put(p.Jira_Account_Id__c, p.Id);
            }
            Integer matchedByKey = 0, matchedDrafts = 0, created = 0, stale = 0;
            Map<String, Atlas_Ticket__c> upserts = new Map<String, Atlas_Ticket__c>();
            Set<Id> conversations = new Set<Id>();
            Map<String, Object> snapshots = new Map<String, Object>();
            Set<Id> usedDrafts = new Set<Id>();
            for (Object item : rows) {
                Map<String, Object> row = (Map<String, Object>) item;
                String key = (String) row.get('key');
                Atlas_Ticket__c r = byKey.get(key);
                Datetime incoming = row.get('updated') == null ? null : (Datetime) JSON.deserialize(JSON.serialize(row.get('updated')), Datetime.class);
                if (r != null && staleSnapshot(r, incoming)) { stale++; continue; }
                if (r != null) matchedByKey++;
                else {
                    List<Atlas_Ticket__c> candidates = drafts.get(matchKey((String) row.get('project'), (String) row.get('summary'), (String) row.get('issueType')));
                    String resolution = (String) row.get('resolution');
                    if (candidates != null && resolution != 'new') {
                        if (candidates.size() == 1 && String.isBlank(resolution)) r = candidates[0];
                        else for (Atlas_Ticket__c candidate : candidates) if (String.valueOf(candidate.Id) == resolution) r = candidate;
                        if (r == null) throw new Atlas_Api.AtlasException('Ambiguous draft match for ' + key + ': explicitly choose a draft or new record.');
                        if (usedDrafts.contains(r.Id)) throw new Atlas_Api.AtlasException('Two Jira keys selected the same draft. Resolve them before importing.');
                        usedDrafts.add(r.Id); matchedDrafts++;
                    } else {
                        if (!String.isBlank(resolution) && resolution != 'new') throw new Atlas_Api.AtlasException('Selected draft no longer matches. Review again.');
                        r = new Atlas_Ticket__c(); created++;
                    }
                }
                if (row.get('expectedVersion') != null) checkVersion(r, row.get('expectedVersion'));
                Map<String, Object> p = planning(r);
                if (row.containsKey('assigneeJiraId')) {
                    String identity = (String) row.get('assigneeJiraId');
                    Id personId = peopleByJira.get(identity);
                    String resolution = (String) row.get('assigneeResolution');
                    if (String.isBlank(identity)) { r.Assignee__c = null; p.remove('unresolvedAssignee'); }
                    else if (personId != null) { r.Assignee__c = personId; p.remove('unresolvedAssignee'); }
                    else if (resolution == 'person' && people.contains((Id) row.get('assigneeId'))) { r.Assignee__c = (Id) row.get('assigneeId'); p.remove('unresolvedAssignee'); }
                    else if (resolution == 'keep') p.put('unresolvedAssignee', identity);
                    else if (resolution == 'unassigned') { r.Assignee__c = null; p.remove('unresolvedAssignee'); }
                    else throw new Atlas_Api.AtlasException('Unknown assignee ' + identity + ': explicitly reconcile, keep current assignment, or confirm unassigned.');
                }
                r.Jira_Key__c = key; r.Stage__c = 'In Jira';
                if (row.get('summary') != null) r.Summary__c = (String) row.get('summary');
                if (row.containsKey('description')) r.Description__c = (String) blankToNull(row.get('description'));
                if (row.get('issueType') != null) r.Issue_Type__c = (String) row.get('issueType');
                if (row.get('status') != null) r.Jira_Status__c = (String) row.get('status');
                if (row.get('statusCategory') != null) r.Jira_Status_Category__c = (String) row.get('statusCategory');
                if (row.get('priority') != null) r.Priority__c = (String) row.get('priority');
                r.Project_Key__c = (String) row.get('project');
                if (row.containsKey('epicKey')) { r.Epic_Key__c = (String) blankToNull(row.get('epicKey')); r.Epic__c = null; }
                if (row.get('epicName') != null) r.Epic_Name__c = (String) row.get('epicName');
                if (row.containsKey('dueDate')) r.Due_Date__c = String.isBlank((String) row.get('dueDate')) ? null : Date.valueOf((String) row.get('dueDate'));
                if (incoming != null) r.Jira_Updated__c = incoming;
                if (row.containsKey('customFields')) {
                    Map<String,Object> custom = customValues(p.get('customFields'));
                    custom.putAll(customValues(row.get('customFields')));
                    p.put('customFields',custom);
                }
                p.remove('manualConfirmationBaseline');
                p.put('lastImport', new Map<String, Object>{ 'at' => Datetime.now(), 'manifestId' => envelope?.get('manifestId'), 'chunk' => envelope?.get('chunk'), 'confirmationBaselineTracked' => true });
                r.Planning__c = JSON.serialize(p); bump(r);
                snapshots.put(key, row.get('raw') ?? row);
                upserts.put(key, r);
                if (r.Conversation__c != null) conversations.add(r.Conversation__c);
            }
            Atlas_Data.assertTicketMutationsAllowed(conversations);
            Set<Id> ids = new Set<Id>();
            if (!upserts.isEmpty()) {
                Id rawId = file('atlas-jira-snapshots.json', JSON.serialize(new Map<String, Object>{ 'snapshots' => snapshots, 'rows' => rows }), null);
                for (Atlas_Ticket__c r : upserts.values()) r.Raw_File__c = rawId;
                upsert as user upserts.values();
                linkEpics(upserts.values());
                for (Atlas_Ticket__c r : upserts.values()) ids.add(r.Id);
                linkFile(rawId, ids);
            }
            Map<String, Object> result = new Map<String, Object>{ 'matchedByKey' => matchedByKey, 'matchedDrafts' => matchedDrafts, 'created' => created, 'stale' => stale, 'applied' => true };
            ContentVersion receipt = new ContentVersion(Title = receiptTitle ?? 'Atlas atlas-import-result', PathOnClient = 'import-receipt.json',
                VersionData = Blob.valueOf(JSON.serialize(result)), Description = digest);
            insert as user receipt;
            if (!ids.isEmpty()) linkFile(receipt.Id, ids);
            result.put('receiptId', receipt.Id);
            return JSON.serialize(result);
        } catch (Exception e) {
            Database.rollback(sp);
            if (envelope == null) throw Atlas_Api.fail(e);
            Map<String, Object> failure = new Map<String, Object>{ 'applied' => false, 'error' => e.getMessage(), 'manifestId' => envelope.get('manifestId'), 'chunk' => envelope.get('chunk') };
            failure.put('receiptId', file('atlas-import-failure.json', JSON.serialize(failure), null));
            return JSON.serialize(failure);
        }
    }

    static Boolean staleSnapshot(Atlas_Ticket__c r, Datetime incoming) {
        if (r.Jira_Updated__c != null && (incoming == null || incoming < r.Jira_Updated__c)) return true;
        Map<String,Object> p = planning(r);
        if (p.get('manualConfirmationBaseline') instanceof Map<String,Object>) {
            Map<String,Object> confirmed = (Map<String,Object>)p.get('manualConfirmationBaseline');
            return incoming == null || JSON.serialize(incoming) == JSON.serialize(confirmed.get('updated'));
        }
        if (incoming != null && incoming != r.Jira_Updated__c) return false;
        // Existing checklists predate the explicit source marker. Their immutable
        // field-confirmation history still protects equal/undated source retries.
        Map<String,Object> lastImport = (Map<String,Object>)p.get('lastImport');
        if (lastImport?.get('confirmationBaselineTracked') == true) return false;
        Datetime importedAt = lastImport?.get('at') == null ? null : (Datetime)JSON.deserialize(JSON.serialize(lastImport.get('at')), Datetime.class);
        for (Object item : pending(r)) {
            Map<String,Object> updateItem = (Map<String,Object>)item;
            for (Object raw : (List<Object>)(updateItem.get('history') ?? new List<Object>())) {
                Map<String,Object> step = (Map<String,Object>)raw;
                if (step.get('done') != true || !String.valueOf(step.get('part')).startsWith('field:') || step.get('at') == null) continue;
                Datetime confirmedAt = (Datetime)JSON.deserialize(JSON.serialize(step.get('at')), Datetime.class);
                if (importedAt == null || confirmedAt >= importedAt) return true;
            }
        }
        return false;
    }

    static String matchKey(String project, String summary, String issueType) {
        return Atlas_Data.aliasKey(project) + '|' + Atlas_Data.aliasKey(summary) + '|' + Atlas_Data.aliasKey(issueType ?? 'Task');
    }

    /** Bounded, repeatable legacy migration: records first, then links across all chunks. */
    @AuraEnabled
    public static String importLegacy(String workspaceJson) {
        Savepoint sp = Database.setSavepoint();
        try {
            Map<String, Object> input = (Map<String, Object>) JSON.deserializeUntyped(workspaceJson);
            String workspaceId = (String)(input.get('workspaceId') ?? input.get('workspace'));
            if (String.isBlank(workspaceId)) throw new Atlas_Api.AtlasException('A stable source workspace identity is required. Import through Library & recovery.');
            if (input.get('taskAtlas') instanceof Map<String, Object>) input = (Map<String, Object>) input.get('taskAtlas');
            List<Object> items = (List<Object>) input.get('items');
            if (items == null || items.size() > 50) throw new Atlas_Api.AtlasException('Migrate at most 50 legacy items per chunk, records phase then links phase.');
            String phase = (String) (input.get('phase') ?? 'records');
            if (phase != 'records' && phase != 'links') throw new Atlas_Api.AtlasException('Choose records or links migration phase.');
            Set<String> origins = new Set<String>(), keys = new Set<String>();
            for (Object item : items) {
                Map<String, Object> t = (Map<String, Object>) item;
                String origin = legacyOrigin(workspaceId, (String) t.get('id'));
                if (origins.contains(origin)) throw new Atlas_Api.AtlasException('Duplicate legacy IDs.');
                origins.add(origin);
                String key = ((String) t.get('key'))?.toUpperCase();
                if (!String.isBlank(key)) {
                    if (!jiraKey(key) || keys.contains(key)) throw new Atlas_Api.AtlasException('Invalid or duplicate legacy Jira key.');
                    keys.add(key);
                }
            }
            Map<String, Atlas_Ticket__c> existing = new Map<String, Atlas_Ticket__c>();
            Map<String, Atlas_Ticket__c> byKey = new Map<String, Atlas_Ticket__c>();
            Set<Id> legacyConversations = new Set<Id>();
            for (Atlas_Ticket__c r : [SELECT Id, Origin_Key__c, Jira_Key__c, Planning__c, Import_Revision__c, Assignee__c, Reporter__c, Epic__c, Pending_Updates__c, Conversation__c
                FROM Atlas_Ticket__c WHERE Origin_Key__c IN :origins OR Jira_Key__c IN :keys WITH USER_MODE FOR UPDATE]) {
                existing.put(r.Origin_Key__c, r); byKey.put(r.Jira_Key__c, r);
                if (phase == 'links' && r.Conversation__c != null) legacyConversations.add(r.Conversation__c);
            }
            if (phase == 'links') Atlas_Data.assertTicketMutationsAllowed(legacyConversations);
            Map<String, Id> people = new Map<String, Id>();
            for (Atlas_Person__c p : [SELECT Id, Jira_Account_Id__c FROM Atlas_Person__c WHERE Jira_Account_Id__c != null WITH USER_MODE]) people.put(p.Jira_Account_Id__c, p.Id);
            Map<String, String> aliases = new Map<String, String>();
            for (Object item : (List<Object>) (input.get('userMappings') ?? new List<Object>())) {
                Map<String, Object> mapping = (Map<String, Object>) item;
                aliases.put(Atlas_Data.aliasKey((String) mapping.get('alias')), (String) mapping.get('userId'));
            }
            Map<String, Object> settings = input.get('settings') instanceof Map<String, Object> ? (Map<String, Object>) input.get('settings') : new Map<String, Object>();
            List<Atlas_Ticket__c> records = new List<Atlas_Ticket__c>();
            Integer skipped = 0, unresolved = 0;
            Set<String> parentOrigins = new Set<String>();
            for (Object item : items) {
                Map<String, Object> t = (Map<String, Object>) item;
                if (!String.isBlank((String) t.get('epicId'))) parentOrigins.add(legacyOrigin(workspaceId, (String) t.get('epicId')));
                for (Object dependency : (List<Object>) (t.get('blockedBy') ?? new List<Object>())) parentOrigins.add(legacyOrigin(workspaceId, (String) dependency));
            }
            Map<String, Atlas_Ticket__c> linked = new Map<String, Atlas_Ticket__c>();
            for (Atlas_Ticket__c r : [SELECT Id, Origin_Key__c, Issue_Type__c FROM Atlas_Ticket__c WHERE Origin_Key__c IN :parentOrigins WITH USER_MODE]) linked.put(r.Origin_Key__c, r);
            Id legacyFile;
            if (phase == 'records' && !items.isEmpty()) legacyFile = file('atlas-legacy-ticket-chunk.json', workspaceJson, null);
            for (Object item : items) {
                Map<String, Object> t = (Map<String, Object>) item;
                String origin = legacyOrigin(workspaceId, (String) t.get('id'));
                Atlas_Ticket__c r = existing.get(origin);
                if (phase == 'records') {
                    if (r != null) { skipped++; continue; }
                    String key = (String) blankToNull(((String) t.get('key'))?.toUpperCase());
                    r = byKey.get(key);
                    Boolean fresh = r == null;
                    if (!fresh)
                        throw new Atlas_Api.AtlasException('Legacy key ' + key + ' already exists outside this recovery receipt. Existing shared tickets were not overwritten. Review and reconcile that record before migration.');
                    if (fresh) r = new Atlas_Ticket__c();
                    Map<String, Object> p = planning(r);
                    p.put('legacyFile', legacyFile); p.put('legacyId', t.get('id'));
                    p.put('lane', t.get('lane') ?? 'Backlog'); p.put('blockerNote', t.get('blockerNote'));
                    p.put('snooze', t.get('reminderSnooze')); p.put('followUp', t.get('followUp') ?? t.get('followUpDate'));
                    p.put('dependencies', t.get('blockedBy') ?? new List<Object>());
                    r.Origin_Key__c = origin;
                    if (fresh) {
                        r.Summary__c = (String) t.get('summary'); r.Description__c = (String) t.get('description');
                        r.Issue_Type__c = (String) (t.get('kind') ?? 'Task'); r.Epic_Name__c = (String) t.get('epicName');
                        r.Jira_Key__c = key; r.Project_Key__c = (String) (t.get('project') ?? settings.get('project'));
                        r.Stage__c = !String.isBlank((String) t.get('archived')) ? 'Archived' : key != null ? 'In Jira' : t.get('stage') == 'Exported' ? 'Exported' : 'Draft';
                        r.Priority__c = (String) t.get('priority'); r.Epic_Key__c = (String) blankToNull(t.get('parentKey'));
                        if (!String.isBlank((String) t.get('dueDate'))) r.Due_Date__c = Date.valueOf((String) t.get('dueDate'));
                        r.Due_Date_Source__c = (String) t.get('dueDateSource'); r.Due_Date_Note__c = (String) t.get('dueDateNote');
                        Map<String, Object> jira = t.get('jira') instanceof Map<String, Object> ? (Map<String, Object>) t.get('jira') : new Map<String, Object>();
                        Map<String,Object> custom = customValues(t.get('customFields'));
                        Map<String,Object> jiraFields = jira.get('fields') instanceof Map<String,Object> ? (Map<String,Object>)jira.get('fields') : new Map<String,Object>();
                        for (Object rawUpdate : (List<Object>)(input.get('jiraUpdates') ?? new List<Object>())) {
                            Map<String,Object> u = (Map<String,Object>)rawUpdate;
                            if (u.get('ticketId') != t.get('id')) continue;
                            for (String field : customValues(u.get('customAfter')).keySet()) {
                                List<Object> values = jiraFields.get(field) instanceof List<Object> ? (List<Object>)jiraFields.get(field) : new List<Object>();
                                if (values.size() == 1) custom.put(field,values[0]);
                            }
                        }
                        p.put('customFields',customValues(custom));
                        r.Jira_Status__c = (String)(jira.get('status') ?? ((Map<String,Object>)(jira.get('values') ?? new Map<String,Object>())).get('status'));
                        for (String field : new List<String>{ 'assignee', 'reporter' }) {
                            String identity = (String) t.get(field);
                            if (String.isBlank(identity) && t.get('assigneeExplicit') != true) identity = (String) settings.get(field);
                            String jiraId = aliases.get(Atlas_Data.aliasKey(identity)) ?? identity;
                            if (people.containsKey(jiraId)) r.put(field == 'assignee' ? 'Assignee__c' : 'Reporter__c', people.get(jiraId));
                            else if (!String.isBlank(identity)) { p.put(field == 'assignee' ? 'unresolvedAssignee' : 'unresolvedReporter', identity); unresolved++; }
                        }
                    }
                    p.put('legacyPreserved', true);
                    r.Planning__c = JSON.serialize(p);
                    if (fresh) {
                        List<Object> history = legacyUpdates((String) t.get('id'), (List<Object>) (input.get('jiraUpdates') ?? new List<Object>()));
                        if (!history.isEmpty()) storePending(r, history);
                    }
                } else {
                    if (r == null) throw new Atlas_Api.AtlasException('Import all records before the links phase. Missing ' + t.get('id'));
                    Map<String, Object> p = planning(r);
                    if (p.get('legacyLinksComplete') == true) { skipped++; continue; }
                    if (!String.isBlank((String) t.get('epicId'))) {
                        Atlas_Ticket__c parent = linked.get(legacyOrigin(workspaceId, (String) t.get('epicId')));
                        if (parent != null && parent.Issue_Type__c == 'Epic' && parent.Id != r.Id) { r.Epic__c = parent.Id; p.remove('unresolvedEpic'); }
                        else { p.put('unresolvedEpic', t.get('epicId')); unresolved++; }
                    }
                    List<Object> dependencies = new List<Object>();
                    for (Object dependency : (List<Object>) (t.get('blockedBy') ?? new List<Object>())) {
                        Atlas_Ticket__c record = linked.get(legacyOrigin(workspaceId, (String) dependency));
                        dependencies.add(record == null ? dependency : String.valueOf(record.Id));
                    }
                    p.put('dependencies', dependencies); p.put('legacyLinksComplete', p.get('unresolvedEpic') == null);
                    r.Planning__c = JSON.serialize(p);
                }
                bump(r); records.add(r);
            }
            upsert as user records;
            Set<Id> ids = new Set<Id>();
            for (Atlas_Ticket__c r : records) ids.add(r.Id);
            if (legacyFile != null && !ids.isEmpty()) linkFile(legacyFile, ids);
            if (phase == 'records') {
                for (Atlas_Ticket__c r : records) {
                    if (!String.isBlank(r.Pending_Updates__c) && r.Pending_Updates__c.startsWith('{')) {
                        Id historyId = (Id) ((Map<String, Object>) JSON.deserializeUntyped(r.Pending_Updates__c)).get('file');
                        linkFile(historyId, new Set<Id>{ r.Id });
                    }
                }
                for (Object item : (List<Object>) (input.get('batches') ?? new List<Object>())) {
                    Map<String, Object> batch = (Map<String, Object>) item;
                    String csv = (String) batch.get('csv');
                    if (csv == null) continue;
                    String title = 'Atlas legacy-export-' + Atlas_Api.sha256(Blob.valueOf(csv)) + '.csv';
                    List<ContentVersion> prior = [SELECT Id FROM ContentVersion WHERE Title = :title WITH USER_MODE LIMIT 1];
                    Id exportId = prior.isEmpty() ? file(title.removeStart('Atlas '), csv, null) : prior[0].Id;
                    // The complete backup/chunk retains original IDs and exact batch metadata.
                    if (prior.isEmpty() && !ids.isEmpty()) linkFile(exportId, ids);
                }
            }
            Map<String, Object> result = new Map<String, Object>{ 'phase' => phase, 'saved' => records.size(), 'skipped' => skipped, 'unresolved' => unresolved, 'legacyFileId' => legacyFile };
            result.put('receiptId', file('atlas-legacy-receipt.json', JSON.serialize(result), null));
            return JSON.serialize(result);
        } catch (Exception e) { Database.rollback(sp); throw Atlas_Api.fail(e); }
    }

    static List<Object> legacyUpdates(String ticketId, List<Object> input) {
        List<Object> history = new List<Object>();
        Map<String, String> names = new Map<String, String>{ 'parentKey' => 'epicKey' };
        for (Object item : input) {
            Map<String, Object> u = (Map<String, Object>) item;
            if (u.get('ticketId') != ticketId) continue;
            Map<String, Object> before = u.get('before') instanceof Map<String, Object> ? (Map<String, Object>) u.get('before') : new Map<String, Object>();
            Map<String, Object> after = u.get('after') instanceof Map<String, Object> ? (Map<String, Object>) u.get('after') : new Map<String, Object>();
            Map<String, Object> changes = new Map<String, Object>(), baseline = new Map<String, Object>(), states = new Map<String, Object>();
            List<Object> applied = (List<Object>) (u.get('appliedFields') ?? new List<Object>());
            Boolean unsupported = false;
            for (String key : after.keySet()) {
                String field = names.get(key) ?? key;
                if (JSON.serialize(after.get(key)) == JSON.serialize(before.get(key))) continue;
                if (!UPDATE_FIELDS.containsKey(field)) { unsupported = true; continue; }
                changes.put(field, after.get(key)); baseline.put(field, blankToNull(before.get(key)));
                if (applied.contains(key)) states.put(field, 'done');
            }
            Map<String,Object> customAfter = customValues(u.get('customAfter')), customBefore = customValues(u.get('customBefore'));
            for (String key : customAfter.keySet()) {
                if (customAfter.get(key) == customBefore.get(key)) continue;
                changes.put('custom:' + key,customAfter.get(key)); baseline.put('custom:' + key,customBefore.get(key));
                if (applied.contains('custom:' + key)) states.put('custom:' + key,'done');
            }
            List<Object> comments = new List<Object>();
            for (Object entry : (List<Object>) (u.get('comments') ?? new List<Object>())) {
                Map<String, Object> c = entry instanceof Map<String, Object> ? (Map<String, Object>) entry : new Map<String, Object>{ 'text' => entry };
                c.put('status', String.isBlank((String) c.get('postedAt')) ? 'pending' : 'done');
                comments.add(c);
            }
            String state = (String) u.get('state');
            String status = new Set<String>{ 'confirmed', 'manual-done' }.contains(state) ? 'done' :
                new Set<String>{ 'dismissed', 'conflict' }.contains(state) ? state : 'pending';
            // Unsupported legacy field proposals remain intact in the original file and are visibly flagged, never executed partially.
            if (unsupported && status == 'pending') status = 'needs-rebase';
            history.add(new Map<String, Object>{ 'id' => 'legacy-' + u.get('id'), 'status' => status,
                'created' => u.get('createdAt'), 'createdBy' => 'Legacy migration', 'changes' => changes, 'baseline' => baseline,
                'fieldStatus' => states, 'comments' => comments, 'legacy' => u,
                'reason' => unsupported ? 'Preserved legacy proposal contains fields requiring a fresh native proposal. Original JSON is retained.' : 'Migrated legacy manual update' });
        }
        return history;
    }

    static String legacyOrigin(String workspaceId, String id) {
        if (String.isBlank(id)) throw new Atlas_Api.AtlasException('Every legacy ticket needs a stable local ID.');
        return 'legacy:' + Atlas_Api.sha256(Blob.valueOf(JSON.serialize(new List<String>{workspaceId,id})));
    }

    /** Linked immutable Files, keyset-paginated; includes full history and exact exports. */
    @AuraEnabled
    public static String ticketFiles(Id ticketId, String afterId) {
        Set<Id> documents = new Set<Id>();
        for (ContentDocumentLink link : [SELECT ContentDocumentId FROM ContentDocumentLink WHERE LinkedEntityId = :ticketId WITH USER_MODE]) documents.add(link.ContentDocumentId);
        Id cursor = String.isBlank(afterId) ? null : (Id) afterId;
        List<ContentVersion> files = Database.query('SELECT Id, Title, CreatedDate FROM ContentVersion WHERE ContentDocumentId IN :documents AND IsLatest = true'
            + (cursor == null ? '' : ' AND Id > :cursor') + ' ORDER BY Id LIMIT 51', AccessLevel.USER_MODE);
        List<Object> rows = new List<Object>();
        String nextCursor;
        for (ContentVersion v : files) {
            if (cursor != null && String.valueOf(v.Id).compareTo(String.valueOf(cursor)) <= 0) continue;
            if (rows.size() == 50) { nextCursor = (String) ((Map<String, Object>) rows[49]).get('id'); break; }
            rows.add(new Map<String, Object>{ 'id' => v.Id, 'title' => v.Title, 'at' => v.CreatedDate });
        }
        return JSON.serialize(new Map<String, Object>{ 'files' => rows, 'nextCursor' => nextCursor });
    }

    /** Build one exact API operation from a versioned local proposal. No ticket is changed here. */
    public static Map<String,Object> prepareLiveWrite(Id ticketId,String part,String updateId,String expectedVersion) {
        List<Atlas_Ticket__c> rows=Database.query('SELECT Description__c, '+FIELDS+' FROM Atlas_Ticket__c WHERE Id=:ticketId',AccessLevel.USER_MODE);
        Atlas_Ticket__c r=rows.isEmpty() ? null : rows[0];
        checkVersion(r,expectedVersion);
        Atlas_Data.assertJiraWritesAllowed(r.Conversation__c);
        Boolean investigation = Atlas_Data.isSupportTicketsConversation(r.Conversation__c);
        if (investigation && part != 'create') throw new Atlas_Api.AtlasException('Support Tickets can only create a Bug for manager review, not update existing Jira work.');
        Atlas_Jira.Config config=Atlas_Jira.config();
        if (!config.connected || !config.writeEnabled) throw new Atlas_Api.AtlasException('Live Jira writes are not enabled. The manual ticket workflow remains available.');
        Map<String,Object> p=planning(r);
        if (r.Stage__c=='Archived' || p.get('unresolvedAssignee')!=null || p.get('unresolvedReporter')!=null || p.get('unresolvedEpic')!=null)
            throw new Atlas_Api.AtlasException('Resolve this ticket’s identities and parent, and unarchive it before preparing a live Jira write.');
        Map<String,Object> request=new Map<String,Object>(), context=new Map<String,Object>{'ticketId'=>ticketId,'part'=>part,'updateId'=>updateId,'version'=>expectedVersion,
            'sourceFingerprint'=>liveSourceFingerprint(r)};
        Set<Id> identities=new Set<Id>();
        if (part=='create') {
            if (r.Stage__c!='Draft' || r.Jira_Key__c!=null || r.Exported_At__c!=null || r.Export_Batch__c!=null)
                throw new Atlas_Api.AtlasException('Only an unexported Draft can be created live. Reconcile previously exported or created tickets first.');
            if (investigation) {
                if (r.Reporter__c!=null || r.Epic__c!=null || r.Epic_Key__c!=null || r.Epic_Name__c!=null || !customValues(p.get('customFields')).isEmpty())
                    throw new Atlas_Api.AtlasException('This Support Tickets draft has a reporter, parent, epic name or custom field that cannot be sent through the manager-review Bug workflow. Review and remove those fields, or use the manual export workflow. Nothing was discarded.');
                if (r.Due_Date__c!=null && r.Due_Date_Source__c=='suggested')
                    throw new Atlas_Api.AtlasException('Confirm the suggested due date with the administrator before a live Support Tickets Bug. Review the draft or use manual export; no date was changed.');
            }
            Map<String,Object> fields=new Map<String,Object>{'project'=>new Map<String,Object>{'key'=>r.Project_Key__c},'issuetype'=>new Map<String,Object>{'name'=>r.Issue_Type__c},'summary'=>r.Summary__c};
            if (r.Description__c!=null) fields.put('description',r.Description__c);
            if (r.Priority__c!=null) fields.put('priority',new Map<String,Object>{'name'=>r.Priority__c});
            if (r.Due_Date__c!=null) fields.put('duedate',String.valueOf(r.Due_Date__c));
            if (r.Assignee__c!=null) { identities.add(r.Assignee__c); fields.put('assignee',liveIdentity(r.Assignee__c,config)); }
            if (r.Reporter__c!=null) { identities.add(r.Reporter__c); fields.put('reporter',liveIdentity(r.Reporter__c,config)); }
            String parent=r.Epic__r?.Jira_Key__c ?? r.Epic_Key__c;
            if (r.Epic__c!=null || parent!=null) {
                if (!jiraKey(parent) || parent.substringBeforeLast('-')!=r.Project_Key__c) throw new Atlas_Api.AtlasException('Create or reconcile the same-project parent Epic in Jira before this child.');
                fields.put(config.apiVersion=='3' ? 'parent' : liveCustomField('Epic Link'),config.apiVersion=='3' ? (Object)new Map<String,Object>{'key'=>parent} : (Object)parent);
                context.put('parentId',r.Epic__c); context.put('parentKey',parent);
            }
            if (r.Issue_Type__c=='Epic' && String.isNotBlank(r.Epic_Name__c)) fields.put(liveCustomField('Epic Name'),r.Epic_Name__c);
            Map<String,Object> custom=customValues(p.get('customFields'));
            for (String name : custom.keySet()) fields.put(liveCustomField(name),custom.get(name));
            if (investigation) fields.put('labels', new List<String>{'atlas-manager-review'});
            request.put('operation','create'); request.put('fields',fields);
        } else {
            request.put('issueKey',Atlas_Jira.issueKey(r.Jira_Key__c));
            Map<String,Object> found;
            for (Object raw : pending(r)) if (((Map<String,Object>)raw).get('id')==updateId) found=(Map<String,Object>)raw;
            if (found==null || found.get('status')!='pending') throw new Atlas_Api.AtlasException('This Jira proposal is no longer pending.');
            if (part!=null && part.startsWith('field:')) {
                String name=part.substring(6);
                Map<String,Object> changes=(Map<String,Object>)found.get('changes'), states=(Map<String,Object>)(found.get('fieldStatus') ?? new Map<String,Object>());
                Map<String,Object> baseline=(Map<String,Object>)found.get('baseline');
                if (!changes.containsKey(name) || states.containsKey(name) || baseline==null || !sameValue(JSON.deserializeUntyped(JSON.serialize(updateValue(r,name))),baseline.get(name)))
                    throw new Atlas_Api.AtlasException('This field proposal is completed or conflicts with the saved ticket. Refresh and prepare a new proposal.');
                Object value=changes.get(name);
                if (name=='status') {
                    Map<String,Object> transitions=Atlas_Jira.run(new Map<String,Object>{'action'=>'transitions','issueKey'=>r.Jira_Key__c});
                    String chosen;
                    for (Object raw : (List<Object>)transitions.get('items')) {
                        Map<String,Object> transition=(Map<String,Object>)raw, target=(Map<String,Object>)transition.get('to');
                        if (target!=null && String.valueOf(value).equals((String)target.get('name'))) {
                            if (chosen!=null) throw new Atlas_Api.AtlasException('More than one transition reaches this status. Use an explicit reviewed transitionId.');
                            chosen=(String)transition.get('id');
                        }
                    }
                    if (chosen==null || transitions.get('hasMore')==true) throw new Atlas_Api.AtlasException('No unique available transition reaches the proposed status. Review Jira transitions explicitly.');
                    request.put('operation','transition'); request.put('transitionId',chosen);
                } else {
                    Map<String,Object> fields=new Map<String,Object>();
                    if (name=='summary' || name=='description') fields.put(name,value);
                    else if (name=='priority') fields.put('priority',new Map<String,Object>{'name'=>value});
                    else if (name=='dueDate') fields.put('duedate',blankToNull(value));
                    else if (name=='assigneeId') {
                        Id identity=(Id)blankToNull(value);
                        if (identity!=null) identities.add(identity);
                        fields.put('assignee',identity==null ? null : liveIdentity(identity,config));
                    } else if (name=='epicKey') {
                        String key=(String)blankToNull(value);
                        if (key!=null) Atlas_Jira.issueKey(key);
                        fields.put(config.apiVersion=='3' ? 'parent' : liveCustomField('Epic Link'),config.apiVersion=='3' && key!=null ? (Object)new Map<String,Object>{'key'=>key} : (Object)key);
                    } else if (name.startsWith('custom:')) fields.put(liveCustomField(name.substring(7)),value);
                    else throw new Atlas_Api.AtlasException('This checklist field is local planning information, not a supported Jira API field.');
                    request.put('operation','update'); request.put('fields',fields);
                }
            } else if (part!=null && part.startsWith('comment:')) {
                Integer index=Integer.valueOf(part.substring(8));
                List<Object> comments=(List<Object>)found.get('comments');
                if (index<0 || index>=comments.size()) throw new Atlas_Api.AtlasException('Unknown Jira comment proposal.');
                Object original=comments[index];
                Map<String,Object> comment=original instanceof Map<String,Object> ? (Map<String,Object>)original : new Map<String,Object>{'text'=>original};
                if (comment.get('status')=='done' || comment.get('status')=='dismissed') throw new Atlas_Api.AtlasException('This comment proposal is already complete.');
                request.put('operation','comment'); request.put('body',comment.get('text'));
            } else throw new Atlas_Api.AtlasException('Choose create, one field, or one comment.');
        }
        context.put('identityVersions',Atlas_Identity.versions(identities));
        // Stable per ticket version and exact checklist part, including after response loss.
        request.put('requestId','ticket-'+Atlas_Api.sha256(Blob.valueOf(ticketId+':'+expectedVersion+':'+part+':'+updateId+':'+config.fingerprint+':'+context.get('sourceFingerprint'))));
        return new Map<String,Object>{'conversationId'=>r.Conversation__c,'request'=>request,'context'=>context};
    }
    static Object liveIdentity(Id personId,Atlas_Jira.Config config) {
        Atlas_Person__c person=[SELECT Jira_Account_Id__c,Active__c FROM Atlas_Person__c WHERE Id=:personId WITH USER_MODE];
        if (!person.Active__c || String.isBlank(person.Jira_Account_Id__c)) throw new Atlas_Api.AtlasException('Choose an active person with a confirmed Jira identity.');
        return new Map<String,Object>{config.apiVersion=='3' ? 'accountId' : 'name'=>person.Jira_Account_Id__c};
    }
    static String liveCustomField(String name) {
        if (Pattern.matches('customfield_[0-9]{1,10}',name)) return name;
        Map<String,Object> metadata=Atlas_Jira.run(new Map<String,Object>{'action'=>'fields'});
        String chosen;
        for (Object raw : (List<Object>)metadata.get('items')) {
            Map<String,Object> field=(Map<String,Object>)raw;
            if (name.equals((String)field.get('name')) && field.get('custom')==true) {
                if (chosen!=null) throw new Atlas_Api.AtlasException('More than one Jira field is named '+name+'. Use the exact customfield ID.');
                chosen=(String)field.get('id');
            }
        }
        if (chosen==null || metadata.get('hasMore')==true) throw new Atlas_Api.AtlasException('Cannot uniquely resolve Jira field '+name+' within the bounded metadata result. Use its exact customfield ID in a direct reviewed request.');
        return chosen;
    }
    static String liveSourceFingerprint(Atlas_Ticket__c row) {
        Blob history=Blob.valueOf(row.Pending_Updates__c ?? '');
        if (String.isNotBlank(row.Pending_Updates__c) && row.Pending_Updates__c.startsWith('{')) {
            Id versionId=(Id)((Map<String,Object>)JSON.deserializeUntyped(row.Pending_Updates__c)).get('file');
            history=[SELECT VersionData FROM ContentVersion WHERE Id=:versionId WITH USER_MODE].VersionData;
        }
        if (history.size()>250000) throw new Atlas_Api.AtlasException('This ticket history exceeds the bounded live-review limit. Use a direct reviewed Jira request instead.');
        Map<String,Object> exact=new Map<String,Object>{'ticket'=>JSON.deserializeUntyped(JSON.serialize(dto(row,true,false))),
            'pendingHistorySha256'=>Atlas_Api.sha256(history)};
        return Atlas_Api.sha256(Blob.valueOf(Atlas_JiraWrites.canonical(exact)));
    }
    public static void checkLiveWriteContext(Map<String,Object> context,Boolean lockTicket) {
        Id ticketId=(Id)context.get('ticketId');
        List<Atlas_Ticket__c> rows=Database.query('SELECT Description__c, '+FIELDS+' FROM Atlas_Ticket__c WHERE Id=:ticketId'+(lockTicket ? ' FOR UPDATE' : ''),AccessLevel.USER_MODE);
        checkVersion(rows.isEmpty() ? null : rows[0],context.get('version'));
        Atlas_Data.assertJiraWritesAllowed(rows[0].Conversation__c);
        if (context.get('sourceFingerprint')==null || !liveSourceFingerprint(rows[0]).equals((String)context.get('sourceFingerprint')))
            throw new Atlas_Api.AtlasException('The exact ticket description or proposal changed after review. Nothing was sent.');
        Map<String,Object> expected=(Map<String,Object>)context.get('identityVersions');
        Set<Id> ids=new Set<Id>(); for (String identity : expected.keySet()) ids.add((Id)identity);
        if (Atlas_Identity.versions(ids)!=expected) throw new Atlas_Api.AtlasException('A reviewed Jira identity changed.');
        if (context.get('parentId')!=null) {
            Id parentId=(Id)context.get('parentId');
            Atlas_Ticket__c parent=[SELECT Jira_Key__c,Stage__c,Issue_Type__c FROM Atlas_Ticket__c WHERE Id=:parentId WITH USER_MODE];
            if (parent.Jira_Key__c!=context.get('parentKey') || parent.Stage__c=='Archived' || parent.Issue_Type__c!='Epic') throw new Atlas_Api.AtlasException('The reviewed Jira parent changed.');
        }
    }
    /** Called only after an unambiguous Jira success, never on a timeout or optimistic approval. */
    public static void confirmLiveWrite(Map<String,Object> context,Map<String,Object> result) {
        checkLiveWriteContext(context,true);
        Id ticketId=(Id)context.get('ticketId');
        String part=(String)context.get('part');
        if (part=='create') {
            Atlas_Ticket__c r=lockTickets(new Set<Id>{ticketId}).get(ticketId);
            checkVersion(r,context.get('version'));
            r.Jira_Key__c=Atlas_Jira.issueKey(result.get('issueKey')); r.Stage__c='In Jira';
            Map<String,Object> p=planning(r); p.put('lastLiveWrite',new Map<String,Object>{'requestId'=>result.get('requestId'),'at'=>Datetime.now()}); r.Planning__c=JSON.serialize(p);
            bump(r); update as user r;
        } else completeUpdatePartInternal(ticketId,(String)context.get('updateId'),part,true,(String)context.get('version'),true);
    }

    /** Points tickets at epic records once both carry Jira keys. */
    static void linkEpics(List<Atlas_Ticket__c> records) {
        Set<String> epicKeys = new Set<String>();
        for (Atlas_Ticket__c r : records) {
            if (r.Epic_Key__c != null) epicKeys.add(r.Epic_Key__c.toUpperCase());
        }
        if (epicKeys.isEmpty()) return;
        Map<String, Id> epics = new Map<String, Id>();
        for (Atlas_Ticket__c e : [SELECT Id, Jira_Key__c FROM Atlas_Ticket__c WHERE Jira_Key__c IN :epicKeys AND Issue_Type__c = 'Epic' WITH USER_MODE]) epics.put(e.Jira_Key__c.toUpperCase(), e.Id);
        List<Atlas_Ticket__c> linked = new List<Atlas_Ticket__c>();
        for (Atlas_Ticket__c r : records) {
            Id epic = r.Epic_Key__c == null ? null : epics.get(r.Epic_Key__c.toUpperCase());
            if (epic != null && epic != r.Epic__c) linked.add(new Atlas_Ticket__c(Id = r.Id, Epic__c = epic));
        }
        update as user linked;
    }
}
