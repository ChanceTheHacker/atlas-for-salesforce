/** Immutable, owner-scoped Jira approvals. Only an explicitly approved committed job may send a mutation. */
public with sharing class Atlas_JiraWrites {
    static final String COLUMNS='Id, OwnerId, Conversation__c, Ticket__c, Ticket_Request_Key__c, Request_Key__c, Request_Id__c, Request__c, Payload__c, Context__c, Config__c, Config_Fingerprint__c, Revision__c, State__c, Result__c, Message__c, Job_Id__c, Operation__c, Path__c, Method__c, CreatedDate';
    public class Mutation {
        public String operation, method, path, payload;
    }
    public static String canonical(Object value) {
        if (value instanceof Map<String,Object>) {
            Map<String,Object> mapValue=(Map<String,Object>)value;
            List<String> keys=new List<String>(mapValue.keySet()); keys.sort();
            List<String> entries=new List<String>();
            for (String key : keys) entries.add(JSON.serialize(key)+':'+canonical(mapValue.get(key)));
            return '{'+String.join(entries,',')+'}';
        }
        if (value instanceof List<Object>) {
            List<String> entries=new List<String>();
            for (Object child : (List<Object>)value) entries.add(canonical(child));
            return '['+String.join(entries,',')+']';
        }
        return JSON.serialize(value);
    }
    public static Object document(String text,Atlas_Jira.Config c) {
        if (text==null) return null;
        if (text.length()>20000) throw Atlas_Jira.problem('Jira text must be at most 20,000 characters.');
        if (c.apiVersion=='2') return text;
        List<Object> lines=new List<Object>();
        for (String line : text.split('\n',-1)) lines.add(new Map<String,Object>{'type'=>'paragraph','content'=>String.isEmpty(line) ? new List<Object>() : new List<Object>{new Map<String,Object>{'type'=>'text','text'=>line}}});
        return new Map<String,Object>{'type'=>'doc','version'=>1,'content'=>lines};
    }
    static Map<String,Object> writeFields(Object value,Atlas_Jira.Config c,Boolean create) {
        if (!(value instanceof Map<String,Object>)) throw Atlas_Jira.problem('Jira fields must be an object.');
        Map<String,Object> fields=(Map<String,Object>)value, out=new Map<String,Object>();
        if (fields.isEmpty() || fields.size()>30) throw Atlas_Jira.problem('Provide 1–30 Jira fields.');
        Set<String> strings=new Set<String>{'summary','description','duedate','environment'};
        Set<String> selectors=new Set<String>{'project','issuetype','priority','assignee','reporter','parent'};
        for (String key : fields.keySet()) {
            Object item=fields.get(key);
            if (strings.contains(key)) {
                if (item!=null && !(item instanceof String)) throw Atlas_Jira.problem('Jira '+key+' must be plain text or null.');
                String text=(String)item;
                if (text!=null && text.length()>(key=='summary' ? 255 : key=='duedate' ? 10 : 20000)) throw Atlas_Jira.problem('Jira '+key+' is too long.');
                if (key=='duedate' && item!=null) Date.valueOf(text);
                out.put(key,key=='description' || key=='environment' ? document(text,c) : item);
            } else if (selectors.contains(key)) {
                if (item==null && (key=='assignee' || key=='parent')) { out.put(key,null); continue; }
                if (!(item instanceof Map<String,Object>)) throw Atlas_Jira.problem('Jira '+key+' requires one explicit identifier.');
                Map<String,Object> selector=(Map<String,Object>)item;
                Set<String> allowed=key=='assignee' || key=='reporter' ? new Set<String>{c.apiVersion=='3' ? 'accountId' : 'name'} : key=='parent' ? new Set<String>{'key'} : new Set<String>{'id','key','name'};
                Atlas_Jira.only(selector,allowed);
                if (selector.size()!=1) throw Atlas_Jira.problem('Use exactly one Jira '+key+' identifier.');
                for (String field : selector.keySet()) Atlas_Jira.text(selector,field,128,true);
                if (key=='parent') Atlas_Jira.issueKey(selector.get('key'));
                out.put(key,selector);
            } else if (key=='labels') {
                if (!(item instanceof List<Object>) || ((List<Object>)item).size()>20) throw Atlas_Jira.problem('Use at most 20 Jira labels.');
                for (Object label : (List<Object>)item) if (!(label instanceof String) || !Pattern.matches('[A-Za-z0-9_-]{1,80}',(String)label)) throw Atlas_Jira.problem('Invalid Jira label.');
                out.put(key,item);
            } else if (Pattern.matches('customfield_[0-9]{1,10}',key)) {
                validateCustom(item,0); out.put(key,item);
            } else throw Atlas_Jira.problem('Unsupported Jira field '+key.left(80)+'. Status changes require a transition.');
        }
        if (create && (!out.containsKey('project') || !out.containsKey('issuetype') || String.isBlank((String)fields.get('summary')))) throw Atlas_Jira.problem('Creating a Jira issue requires project, issuetype and summary.');
        if (!create && (out.containsKey('project') || out.containsKey('issuetype'))) throw Atlas_Jira.problem('Moving issues or changing their type is not supported.');
        return out;
    }
    static void validateCustom(Object value,Integer depth) {
        if (depth>3) throw Atlas_Jira.problem('Custom Jira field values are nested too deeply.');
        if (value instanceof String) { if (((String)value).length()>20000) throw Atlas_Jira.problem('Custom Jira field text is too long.'); }
        else if (value instanceof List<Object>) {
            if (((List<Object>)value).size()>30) throw Atlas_Jira.problem('Custom Jira field lists are limited to 30 items.');
            for (Object child : (List<Object>)value) validateCustom(child,depth+1);
        } else if (value instanceof Map<String,Object>) {
            Map<String,Object> mapValue=(Map<String,Object>)value;
            Atlas_Jira.only(mapValue,new Set<String>{'id','value','name','accountId','child'});
            if (mapValue.size()>3) throw Atlas_Jira.problem('Unsupported custom Jira field value.');
            for (Object child : mapValue.values()) validateCustom(child,depth+1);
        } else if (value!=null && !(value instanceof Boolean) && !(value instanceof Decimal) && !(value instanceof Integer)) throw Atlas_Jira.problem('Unsupported custom Jira field value.');
    }
    public static Mutation mutation(Map<String,Object> request,Atlas_Jira.Config c) {
        Atlas_Jira.only(request,new Set<String>{'requestId','operation','issueKey','fields','body','transitionId'});
        String requestId=Atlas_Jira.text(request,'requestId',100,true);
        if (!Pattern.matches('[A-Za-z0-9_-]{1,100}',requestId)) throw Atlas_Jira.problem('Use a stable requestId containing letters, numbers, underscores or hyphens.');
        Mutation m=new Mutation(); m.operation=Atlas_Jira.text(request,'operation',20,true);
        m.path='/rest/api/'+c.apiVersion+'/issue'; m.method='POST';
        Map<String,Object> payload=new Map<String,Object>();
        if (m.operation=='create' || m.operation=='update') {
            if (request.containsKey('body') || request.containsKey('transitionId') || (m.operation=='create' && request.containsKey('issueKey'))) throw Atlas_Jira.problem('Unexpected property for Jira issue mutation.');
            payload.put('fields',writeFields(request.get('fields'),c,m.operation=='create'));
            if (m.operation=='update') { m.method='PUT'; m.path+='/'+Atlas_Jira.issueKey(request.get('issueKey')); }
        } else if (m.operation=='comment') {
            if (request.containsKey('fields') || request.containsKey('transitionId')) throw Atlas_Jira.problem('Unexpected property for Jira comment.');
            m.path+='/'+Atlas_Jira.issueKey(request.get('issueKey'))+'/comment';
            payload.put('body',document(Atlas_Jira.text(request,'body',20000,true),c));
        } else if (m.operation=='transition') {
            if (request.containsKey('fields') || request.containsKey('body')) throw Atlas_Jira.problem('Transition supports only an exact transitionId.');
            String transition=Atlas_Jira.text(request,'transitionId',30,true);
            if (!Pattern.matches('[0-9]{1,30}',transition)) throw Atlas_Jira.problem('Use an exact numeric Jira transitionId.');
            m.path+='/'+Atlas_Jira.issueKey(request.get('issueKey'))+'/transitions';
            payload.put('transition',new Map<String,Object>{'id'=>transition});
        } else throw Atlas_Jira.problem('Supported Jira writes are create, update, comment and transition.');
        m.payload=canonical(payload);
        if (m.payload.length()>60000) throw Atlas_Jira.problem('Jira payload exceeds 60,000 characters.');
        return m;
    }
    static void access() {
        if (!Schema.SObjectType.Atlas_Jira_Operation__c.isAccessible()) throw Atlas_Jira.problem('You do not have access to Jira approval records.');
    }
    static Atlas_Jira_Operation__c load(Id operationId,Boolean lockRow) {
        access();
        List<Atlas_Jira_Operation__c> rows=Database.query('SELECT '+COLUMNS+' FROM Atlas_Jira_Operation__c WHERE Id=:operationId'+(lockRow ? ' FOR UPDATE' : ''),AccessLevel.USER_MODE);
        if (rows.isEmpty() || rows[0].OwnerId!=UserInfo.getUserId()) throw Atlas_Jira.problem('This Jira operation does not belong to you or is inaccessible.');
        return rows[0];
    }
    @AuraEnabled
    public static String prepareWrite(Id conversationId,String requestJson) {
        try { return prepare(conversationId,requestJson,null); }
        catch (Exception e) { throw Atlas_Api.fail(e); }
    }
    /** Support Tickets investigates production; its only remote write is a reviewed Bug routed to the manager for triage. */
    static void guardSupportTicketsRequest(Id conversationId,Map<String,Object> request) {
        Atlas_Data.assertJiraWritesAllowed(conversationId);
        if (!Atlas_Data.isSupportTicketsConversation(conversationId)) return;
        if (!'create'.equals((String)request.get('operation')) || !(request.get('fields') instanceof Map<String,Object>))
            throw Atlas_Jira.problem('Support Tickets can only propose a new Bug for manager review. Existing Jira issues cannot be changed from this mode.');
        Map<String,Object> fields=(Map<String,Object>)request.get('fields');
        Atlas_Jira.only(fields,new Set<String>{'project','issuetype','summary','description','assignee','labels','priority','duedate'});
        List<Atlas_Setting__c> saved=[SELECT Data__c FROM Atlas_Setting__c WHERE Key__c='jira' WITH USER_MODE LIMIT 1];
        Map<String,Object> settings=saved.isEmpty() || String.isBlank(saved[0].Data__c)
            ? new Map<String,Object>() : (Map<String,Object>)JSON.deserializeUntyped(saved[0].Data__c);
        Object project=settings.get('projectKey');
        if (!(project instanceof String) || !Pattern.matches('[A-Z][A-Z0-9_]*',(String)project))
            throw Atlas_Jira.problem('Set a valid Jira project key in Team & Jira before preparing a live Support Tickets Bug.');
        if (!canonical(fields.get('project')).equals(canonical(new Map<String,Object>{'key'=>project})))
            throw Atlas_Jira.problem('The Support Tickets Bug must use the configured project key exactly.');
        Atlas_Jira.text(fields,'summary',255,true);
        Atlas_Jira.text(fields,'description',20000,true);
        if (fields.containsKey('priority')) {
            if (!(fields.get('priority') instanceof Map<String,Object>)) throw Atlas_Jira.problem('Support Tickets priority must contain only an explicit name.');
            Map<String,Object> priority=(Map<String,Object>)fields.get('priority');
            Atlas_Jira.only(priority,new Set<String>{'name'}); Atlas_Jira.text(priority,'name',128,true);
        }
        if (fields.containsKey('duedate')) {
            String dueDate=Atlas_Jira.text(fields,'duedate',10,true);
            try {
                if (!Pattern.matches('[0-9]{4}-[0-9]{2}-[0-9]{2}',dueDate) || !String.valueOf(Date.valueOf(dueDate)).equals(dueDate))
                    throw Atlas_Jira.problem('Invalid date.');
            } catch (Exception e) { throw Atlas_Jira.problem('Support Tickets due date must be a real date in YYYY-MM-DD format, explicitly reported by the administrator.'); }
        }
        if (!canonical(fields.get('issuetype')).equals(canonical(new Map<String,Object>{'name'=>'Bug'})))
            throw Atlas_Jira.problem('Support Tickets escalation must create an explicit Bug, not another issue type.');
        Map<String,Object> manager=Atlas_Jira.reviewManager();
        if (manager.get('ready')!=true) throw Atlas_Jira.problem((String)manager.get('message'));
        Map<String,Object> recipient=new Map<String,Object>{(String)manager.get('identityType')=>manager.get('jiraId')};
        if (!canonical(fields.get('assignee')).equals(canonical(recipient)))
            throw Atlas_Jira.problem('Assign this Bug only to the configured review manager for triage and assignment, not to a repair developer.');
        if (!canonical(fields.get('labels')).equals(canonical(new List<Object>{'atlas-manager-review'})))
            throw Atlas_Jira.problem('Include exactly the atlas-manager-review label so the manager can identify Bugs awaiting triage.');
    }
    static String prepare(Id conversationId,String requestJson,Map<String,Object> context) {
        access();
        if (requestJson==null || requestJson.length()>65000) throw Atlas_Jira.problem('Jira request exceeds 65,000 characters.');
        if (conversationId!=null) {
            Atlas_Conversation__c conversation=[SELECT Id FROM Atlas_Conversation__c WHERE Id=:conversationId WITH USER_MODE];
        } else if (context==null) throw Atlas_Jira.problem('A conversation is required for a direct Jira request.');
        Map<String,Object> request=(Map<String,Object>)JSON.deserializeUntyped(requestJson);
        guardSupportTicketsRequest(conversationId,request);
        Atlas_Jira.Config c=Atlas_Jira.config();
        Mutation m=mutation(request,c);
        String requestText=canonical(request), contextText=context==null ? null : canonical(context);
        String key=Atlas_Api.sha256(Blob.valueOf(UserInfo.getUserId()+':'+conversationId+':'+request.get('requestId')));
        List<Atlas_Jira_Operation__c> prior=Database.query('SELECT '+COLUMNS+' FROM Atlas_Jira_Operation__c WHERE Request_Key__c=:key',AccessLevel.USER_MODE);
        if (!prior.isEmpty()) {
            if (!requestText.equals(prior[0].Request__c) || contextText!=prior[0].Context__c) throw Atlas_Jira.problem('This requestId already belongs to different reviewed content. Keep the original ID for retries; use a new ID only for an intentionally new action.');
            return view(prior[0]);
        }
        Atlas_Jira.verify(c,true);
        String revision=revision(m,c.fingerprint,contextText);
        String ticketKey;
        if (context!=null) {
            ticketKey=Atlas_JiraReservations.key((Id)context.get('ticketId'),(String)context.get('part'),(String)context.get('updateId'));
            // Global unique reservation also protects against another user's simultaneous approval.
            // Lock even a private reservation before the ticket, without revealing its contents.
            Atlas_JiraReservations.lockForPreparation(ticketKey);
            List<Atlas_Jira_Operation__c> reserved=Database.query('SELECT '+COLUMNS+' FROM Atlas_Jira_Operation__c WHERE Ticket_Request_Key__c=:ticketKey FOR UPDATE',AccessLevel.USER_MODE);
            // After metadata calls, use the same operation-then-ticket lock order as approval.
            Atlas_Tickets.checkLiveWriteContext(context,true);
            for (Atlas_Jira_Operation__c old : reserved) {
                if (old.OwnerId!=UserInfo.getUserId() || old.State__c!='reviewed') throw Atlas_Jira.problem('This ticket action already has a saved Jira operation. Recover that operation; do not create a duplicate.');
                old.State__c='invalidated'; old.Ticket_Request_Key__c=null; old.Message__c='Superseded before approval by a new exact review. Nothing was sent.'; update old;
            }
        }
        Atlas_Jira_Operation__c row=new Atlas_Jira_Operation__c(Ticket_Request_Key__c=ticketKey,Conversation__c=conversationId,Ticket__c=context==null ? null : (Id)context.get('ticketId'),
            Request_Key__c=key,Request_Id__c=(String)request.get('requestId'),Request__c=requestText,Payload__c=m.payload,Context__c=contextText,
            Config__c=snapshot(c),Config_Fingerprint__c=c.fingerprint,Revision__c=revision,State__c='reviewed',Operation__c=m.operation,Path__c=m.path,Method__c=m.method,
            Message__c='Review this exact Jira request. Nothing has been sent.');
        // Operations are read-only through ordinary record APIs. This class is the sole state writer.
        insert row;
        return view(row);
    }
    static String snapshot(Atlas_Jira.Config c) {
        return canonical(new Map<String,Object>{'siteUrl'=>c.siteUrl,'apiBaseUrl'=>c.apiBaseUrl,'namedCredential'=>c.namedCredential,'externalCredential'=>c.externalCredential,'apiVersion'=>c.apiVersion});
    }
    static String revision(Mutation m,String fingerprint,String context) {
        return Atlas_Api.sha256(Blob.valueOf(canonical(new Map<String,Object>{'method'=>m.method,'path'=>m.path,'payload'=>m.payload,'config'=>fingerprint,'context'=>context})));
    }
    @AuraEnabled
    public static String prepareTicketWrite(Id ticketId,String part,String updateId,String expectedVersion) {
        try {
            Map<String,Object> prepared=Atlas_Tickets.prepareLiveWrite(ticketId,part,updateId,expectedVersion);
            return prepare((Id)prepared.get('conversationId'),JSON.serialize(prepared.get('request')),(Map<String,Object>)prepared.get('context'));
        } catch (Exception e) { throw Atlas_Api.fail(e); }
    }
    @AuraEnabled
    public static String approveWrite(Id operationId,String expectedRevision) {
        try {
            Atlas_Jira_Operation__c row=load(operationId,true);
            if (expectedRevision==null || !expectedRevision.equals(row.Revision__c)) throw Atlas_Jira.problem('The Jira review changed. Open and review the exact request again.');
            if (row.State__c!='reviewed') return view(row); // Exact replay never schedules another callout.
            Atlas_Data.assertJiraWritesAllowed(row.Conversation__c);
            Atlas_Jira.Config c=Atlas_Jira.config();
            if (!c.fingerprint.equals(row.Config_Fingerprint__c)) {
                row.State__c='invalidated'; row.Ticket_Request_Key__c=null; row.Message__c='Jira configuration changed after review. Nothing was sent. Prepare a new review.'; update row; return view(row);
            }
            Atlas_Jira.verify(c,true);
            verifyPayload(row,c);
            if (row.Ticket__c!=null) Atlas_Tickets.checkLiveWriteContext((Map<String,Object>)JSON.deserializeUntyped(row.Context__c),true);
            row.State__c='queued'; row.Message__c='Approved and queued. Poll this saved operation; do not submit it again.';
            row.Job_Id__c=System.enqueueJob(new Atlas_JiraWriteJob(row.Id));
            update row;
            return view(row);
        } catch (Exception e) { throw Atlas_Api.fail(e); }
    }
    static void verifyPayload(Atlas_Jira_Operation__c row,Atlas_Jira.Config c) {
        Map<String,Object> request=(Map<String,Object>)JSON.deserializeUntyped(row.Request__c);
        guardSupportTicketsRequest(row.Conversation__c,request);
        Mutation m=mutation(request,c);
        if (!snapshot(c).equals(row.Config__c) || !m.payload.equals(row.Payload__c) || !m.path.equals(row.Path__c) || !m.method.equals(row.Method__c) || !revision(m,row.Config_Fingerprint__c,row.Context__c).equals(row.Revision__c))
            throw Atlas_Jira.problem('The stored Jira review failed its integrity check. Nothing was sent.');
    }
    @AuraEnabled
    public static String getWrite(Id operationId) {
        try { Atlas_Jira_Operation__c row=load(operationId,false); recover(row); return view(row); }
        catch (Exception e) { throw Atlas_Api.fail(e); }
    }
    @AuraEnabled
    public static String listWrites(Id conversationId) {
        try { return summaries(conversationId,null); }
        catch (Exception e) { throw Atlas_Api.fail(e); }
    }
    @AuraEnabled
    public static String listTicketWrites(Id ticketId) {
        try {
            if (ticketId==null || ticketId.getSObjectType()!=Atlas_Ticket__c.SObjectType) throw Atlas_Jira.problem('Choose a ticket for Jira operation recovery.');
            Atlas_Ticket__c ticket=[SELECT Id FROM Atlas_Ticket__c WHERE Id=:ticketId WITH USER_MODE];
            return summaries(null,ticketId);
        } catch (Exception e) { throw Atlas_Api.fail(e); }
    }
    static String summaries(Id conversationId,Id ticketId) {
        access(); Id owner=UserInfo.getUserId();
        List<Object> results=new List<Object>();
        // Never load request, payload, config, context or result long text into a list response.
        String columns='Id, Conversation__c, Ticket__c, Revision__c, Request_Id__c, State__c, Operation__c, Message__c, CreatedDate';
        String filter=ticketId==null ? 'Conversation__c=:conversationId' : 'Ticket__c=:ticketId';
        for (Atlas_Jira_Operation__c row : Database.query('SELECT '+columns+' FROM Atlas_Jira_Operation__c WHERE OwnerId=:owner AND '+filter+' ORDER BY CreatedDate DESC LIMIT 50',AccessLevel.USER_MODE)) {
            results.add(new Map<String,Object>{'summary'=>true,'id'=>row.Id,'revision'=>row.Revision__c,'requestId'=>row.Request_Id__c,'state'=>row.State__c,
                'operation'=>row.Operation__c,'message'=>row.Message__c,'conversationId'=>row.Conversation__c,'ticketId'=>row.Ticket__c,'created'=>row.CreatedDate});
        }
        return JSON.serialize(results);
    }
    static void recover(Atlas_Jira_Operation__c row) {
        if (row.State__c!='queued') return;
        Id jobId=(Id)row.Job_Id__c;
        List<AsyncApexJob> jobs=[SELECT Status FROM AsyncApexJob WHERE Id=:jobId];
        if (jobs.isEmpty() || new Set<String>{'Completed','Failed','Aborted'}.contains(jobs[0].Status)) {
            Atlas_Jira_Operation__c current=load(row.Id,true);
            if (current.State__c=='queued') {
                current.State__c='unknown'; current.Message__c='The worker ended without a saved outcome. Jira may have changed. Check Jira before any new operation. This request will never be resent.';
                update current;
            }
            row.State__c=current.State__c; row.Message__c=current.Message__c; row.Result__c=current.Result__c;
        }
    }
    static String view(Atlas_Jira_Operation__c row) {
        Map<String,Object> context=String.isBlank(row.Context__c) ? new Map<String,Object>() : (Map<String,Object>)JSON.deserializeUntyped(row.Context__c);
        Map<String,Object> savedConfig=(Map<String,Object>)JSON.deserializeUntyped(row.Config__c);
        return JSON.serialize(new Map<String,Object>{'apiBaseUrl'=>savedConfig.get('apiBaseUrl'),'siteUrl'=>savedConfig.get('siteUrl'),
            'namedCredential'=>savedConfig.get('namedCredential'),'externalCredential'=>savedConfig.get('externalCredential'),'apiVersion'=>savedConfig.get('apiVersion'),
            'id'=>row.Id,'revision'=>row.Revision__c,'requestId'=>row.Request_Id__c,'state'=>row.State__c,
            'operation'=>row.Operation__c,'method'=>row.Method__c,'path'=>row.Path__c,'payload'=>JSON.deserializeUntyped(row.Payload__c),
            'result'=>String.isBlank(row.Result__c) ? null : JSON.deserializeUntyped(row.Result__c),'message'=>row.Message__c,
            'ticketId'=>row.Ticket__c,'part'=>context.get('part'),'updateId'=>context.get('updateId'),'conversationId'=>row.Conversation__c});
    }
    /** Called once by the recorded Queueable, in a separate transaction after approval commits. */
    public static void executeApproved(Id operationId,Id jobId,Atlas_Jira.CredentialInspector inspector) {
        Atlas_Jira_Operation__c row=load(operationId,false);
        if (row.State__c!='queued' || row.Job_Id__c!=String.valueOf(jobId)) return;
        Atlas_Jira.Config c;
        try {
            Atlas_Data.assertJiraWritesAllowed(row.Conversation__c);
            c=Atlas_Jira.config();
            if (!c.fingerprint.equals(row.Config_Fingerprint__c)) throw Atlas_Jira.problem('Jira configuration changed.');
            Atlas_Jira.verify(c,true,inspector); verifyPayload(row,c);
            if (row.Ticket__c!=null) Atlas_Tickets.checkLiveWriteContext((Map<String,Object>)JSON.deserializeUntyped(row.Context__c),false);
        } catch (Exception e) {
            row.State__c='invalidated'; row.Ticket_Request_Key__c=null; row.Message__c='Configuration, access, or the reviewed ticket changed before execution. Nothing was sent.'; update row; return;
        }
        Map<String,Object> result=new Map<String,Object>{'requestId'=>row.Request_Id__c,'attempted'=>true,'mirrorSynced'=>false};
        try {
            HttpResponse response=Atlas_Jira.send(c,row.Method__c,row.Path__c,row.Payload__c);
            Integer status=response.getStatusCode(); result.put('httpStatus',status);
            Boolean success=false;
            if ((row.Operation__c=='update' || row.Operation__c=='transition') && status==204) success=true;
            else if ((row.Operation__c=='create' || row.Operation__c=='comment') && status==201) {
                Map<String,Object> answer=(Map<String,Object>)Atlas_Jira.parseResponse(response);
                if (row.Operation__c=='create') { result.put('issueKey',Atlas_Jira.issueKey(answer.get('key'))); success=true; }
                else {
                    String id=Atlas_Jira.text(answer,'id',30,true);
                    if (!Pattern.matches('[0-9]{1,30}',id)) throw Atlas_Jira.problem('Unrecognized Jira comment receipt.');
                    result.put('commentId',id); success=true;
                }
            }
            if (success) {
                row.State__c='succeeded'; row.Message__c='Jira confirmed the exact approved operation.';
                if (row.Ticket__c!=null) {
                    try { Atlas_Tickets.confirmLiveWrite((Map<String,Object>)JSON.deserializeUntyped(row.Context__c),result); result.put('mirrorSynced',true); }
                    catch (Exception e) { row.Message__c='Jira confirmed success, but the saved ticket could not be synchronized. Refresh or reconcile the mirror; do not resend this operation.'; }
                }
            } else if (status>=400 && status<500 && status!=408) {
                row.State__c='failed'; row.Ticket_Request_Key__c=null; row.Message__c='Jira rejected the request (HTTP '+status+'). No automatic retry was attempted. Review permissions and field values.';
            } else {
                row.State__c='unknown'; row.Message__c='Jira did not return an unambiguous completion receipt. Check Jira before proposing another operation. This operation will not be retried.';
            }
        } catch (Exception e) {
            row.State__c='unknown'; row.Message__c='Jira may have received this operation, but its outcome could not be verified. Check Jira; do not resend. No automatic retry was attempted.';
        }
        row.Result__c=JSON.serialize(result);
        // If this persistence fails, approval/job ID remain committed. getWrite reports unknown, never requeues.
        update row;
    }
}
