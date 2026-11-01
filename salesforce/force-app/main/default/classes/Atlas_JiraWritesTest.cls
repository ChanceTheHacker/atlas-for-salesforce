@IsTest
private class Atlas_JiraWritesTest {
    @TestSetup static void setup() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_JiraTest.settings(true,true,'3');
            Atlas_Setting__c saved=[SELECT Id,Data__c FROM Atlas_Setting__c WHERE Key__c='jira'];
            Map<String,Object> settings=read(saved.Data__c); settings.put('projectKey','DEMO'); saved.Data__c=JSON.serialize(settings); update saved;
            insert new Atlas_Conversation__c(Name='Jira approval',Mode__c='Task',Status__c='Open');
            insert new Atlas_Ticket__c(Summary__c='Draft for Jira',Description__c='Reviewed description',Project_Key__c='DEMO',Issue_Type__c='Task',Stage__c='Draft');
        }
    }
    static Id conversation() { return [SELECT Id FROM Atlas_Conversation__c LIMIT 1].Id; }
    static Map<String,Object> read(String value) { return (Map<String,Object>)JSON.deserializeUntyped(value); }
    static String createRequest(String requestId) {
        return JSON.serialize(new Map<String,Object>{'requestId'=>requestId,'operation'=>'create','fields'=>new Map<String,Object>{'project'=>new Map<String,Object>{'key'=>'DEMO'},'issuetype'=>new Map<String,Object>{'name'=>'Task'},'summary'=>'Exact reviewed summary','description'=>'First line\nSecond line'}});
    }
    static Map<String,Object> prepare(String request) {
        Atlas_Jira.inspector=new Atlas_JiraTest.Credentials();
        return read(Atlas_JiraWrites.prepareWrite(conversation(),request));
    }
    class MutationReply implements HttpCalloutMock {
        Integer status; String body; Boolean timeout;
        MutationReply(Integer status,String body) { this.status=status; this.body=body; timeout=false; }
        MutationReply(Boolean timeout) { this.timeout=timeout; }
        public HttpResponse respond(HttpRequest request) {
            System.assertEquals('POST',request.getMethod());
            System.assertEquals('callout:Any_Jira_Connection/rest/api/3/issue',request.getEndpoint());
            // A committed approval and job identity must exist before the actual mutation.
            Atlas_Jira_Operation__c row=[SELECT State__c,Payload__c,Job_Id__c FROM Atlas_Jira_Operation__c WHERE State__c='queued' LIMIT 1];
            System.assertNotEquals(null,row.Job_Id__c);
            System.assertEquals(row.Payload__c,request.getBody());
            if (timeout) throw new CalloutException('SECRET internal credential detail');
            HttpResponse response=new HttpResponse(); response.setStatusCode(status); response.setBody(body); return response;
        }
    }
    static Id supportTicketsConversation() {
        Atlas_Conversation__c row=new Atlas_Conversation__c(Name='Production QA',Mode__c='support-tickets',Status__c='Open'); insert row; return row.Id;
    }
    static Id configureReviewManager(String identityType) {
        Atlas_Person__c manager=new Atlas_Person__c(Name='Bug triage manager',Active__c=true,Jira_Account_Id__c='manager-jira-id'); insert manager;
        Atlas_Setting__c saved=[SELECT Id,Data__c FROM Atlas_Setting__c WHERE Key__c='jira'];
        Map<String,Object> settings=read(saved.Data__c); settings.put('projectKey','DEMO'); settings.put('reviewManagerPersonId',manager.Id); settings.put('reviewManagerIdentityType',identityType);
        Atlas_Jira.inspector=new Atlas_JiraTest.Credentials();
        Atlas_Data.saveSetting('jira',JSON.serialize(settings)); return manager.Id;
    }
    static Map<String,Object> bugRequest(String id,String identityType) {
        return new Map<String,Object>{'requestId'=>id,'operation'=>'create','fields'=>new Map<String,Object>{
            'project'=>new Map<String,Object>{'key'=>'DEMO'},'issuetype'=>new Map<String,Object>{'name'=>'Bug'},
            'summary'=>'Suspected automation bug','description'=>'Manager review and assignment required. The manager is not the repair developer.',
            'assignee'=>new Map<String,Object>{identityType=>'manager-jira-id'},'labels'=>new List<Object>{'atlas-manager-review'}}};
    }
    @IsTest static void supportTicketsAllowsOnlyManagerRoutedBugCreation() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Id conversationId=supportTicketsConversation(); configureReviewManager('accountId');
            for (String request : new List<String>{
                '{"requestId":"bad-update","operation":"update","issueKey":"DEMO-1","fields":{"summary":"Changed"}}',
                '{"requestId":"bad-comment","operation":"comment","issueKey":"DEMO-1","body":"Comment"}',
                '{"requestId":"bad-transition","operation":"transition","issueKey":"DEMO-1","transitionId":"11"}',
                createRequest('bad-task')}) {
                try { Atlas_JiraWrites.prepareWrite(conversationId,request); System.assert(false,request); }
                catch (AuraHandledException expected) { System.assert(expected.getMessage().contains('Support Tickets')); }
            }
            for (String altered : new List<String>{'assignee','labels','issuetype'}) {
                Map<String,Object> request=bugRequest('bad-'+altered,'accountId'), fields=(Map<String,Object>)request.get('fields');
                if (altered=='assignee') fields.put('assignee',new Map<String,Object>{'accountId'=>'repair-developer'});
                if (altered=='labels') fields.remove('labels');
                if (altered=='issuetype') fields.put('issuetype',new Map<String,Object>{'id'=>'10001'});
                try { Atlas_JiraWrites.prepareWrite(conversationId,JSON.serialize(request)); System.assert(false,altered); }
                catch (AuraHandledException expected) { System.assertNotEquals(null,expected.getMessage()); }
            }
            Map<String,Object> review=read(Atlas_JiraWrites.prepareWrite(conversationId,JSON.serialize(bugRequest('good-bug','accountId'))));
            System.assertEquals('reviewed',review.get('state'));
            System.assertEquals(0,Limits.getCallouts()); System.assertEquals(0,Limits.getQueueableJobs());
            Map<String,Object> fields=(Map<String,Object>)((Map<String,Object>)review.get('payload')).get('fields');
            System.assertEquals('manager-jira-id',((Map<String,Object>)fields.get('assignee')).get('accountId'));
            System.assertEquals('Bug',((Map<String,Object>)fields.get('issuetype')).get('name'));
            Test.setMock(HttpCalloutMock.class,new MutationReply(201,'{"key":"DEMO-123"}'));
            Test.startTest(); Atlas_JiraWrites.approveWrite((Id)review.get('id'),(String)review.get('revision')); Test.stopTest();
            System.assertEquals('succeeded',read(Atlas_JiraWrites.getWrite((Id)review.get('id'))).get('state'));
        }
    }
    @IsTest static void supportTicketsDoesNotGuessMissingOrDataCenterIdentities() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Id conversationId=supportTicketsConversation();
            Map<String,Object> manager=Atlas_Jira.reviewManager();
            System.assertEquals('unconfigured',manager.get('status'));
            System.assertEquals(false,manager.get('ready'));
            System.assertEquals('',manager.get('personId'));
            System.assertEquals('',manager.get('jiraId'));
            try { Atlas_JiraWrites.prepareWrite(conversationId,JSON.serialize(bugRequest('no-manager','accountId'))); System.assert(false,'A Bug cannot be routed without a Manager.'); }
            catch (AuraHandledException expected) { System.assertEquals(manager.get('message'),expected.getMessage()); }
            System.assertEquals(0,[SELECT COUNT() FROM Atlas_Jira_Operation__c]);
            Atlas_JiraTest.settings(true,true,'2'); configureReviewManager('accountId');
            manager=Atlas_Jira.reviewManager();
            System.assertEquals('identity_type_mismatch',manager.get('status'));
            System.assertEquals(false,manager.get('ready'));
            try { Atlas_JiraWrites.prepareWrite(conversationId,JSON.serialize(bugRequest('wrong-type','accountId'))); System.assert(false,'A Cloud account ID cannot be guessed as a Data Center username.'); }
            catch (AuraHandledException expected) { System.assert(expected.getMessage().contains('identity type'),expected.getMessage()); }
            System.assertEquals(0,[SELECT COUNT() FROM Atlas_Jira_Operation__c]);
            System.assertEquals(0,Limits.getCallouts()); System.assertEquals(0,Limits.getQueueableJobs());
            Atlas_Setting__c saved=[SELECT Id,Data__c FROM Atlas_Setting__c WHERE Key__c='jira'];
            Map<String,Object> settings=read(saved.Data__c); settings.put('reviewManagerIdentityType','name'); Atlas_Data.saveSetting('jira',JSON.serialize(settings));
            System.assertEquals(true,Atlas_Jira.reviewManager().get('ready'));
            Map<String,Object> review=read(Atlas_JiraWrites.prepareWrite(conversationId,JSON.serialize(bugRequest('dc-bug','name'))));
            System.assertEquals('/rest/api/2/issue',review.get('path'));
            Map<String,Object> fields=(Map<String,Object>)((Map<String,Object>)review.get('payload')).get('fields');
            System.assertEquals('manager-jira-id',((Map<String,Object>)fields.get('assignee')).get('name'));
            System.assertEquals(0,Limits.getCallouts());
        }
    }
    @IsTest static void supportTicketsRechecksManagerBeforeApproval() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Id conversationId=supportTicketsConversation(), managerId=configureReviewManager('accountId');
            Map<String,Object> review=read(Atlas_JiraWrites.prepareWrite(conversationId,JSON.serialize(bugRequest('manager-changes','accountId'))));
            update new Atlas_Person__c(Id=managerId,Active__c=false);
            try { Atlas_JiraWrites.approveWrite((Id)review.get('id'),(String)review.get('revision')); System.assert(false); }
            catch (AuraHandledException expected) { System.assert(expected.getMessage().contains('inactive')); }
            update new Atlas_Person__c(Id=managerId,Active__c=true,Jira_Account_Id__c='changed-manager-id');
            try { Atlas_JiraWrites.approveWrite((Id)review.get('id'),(String)review.get('revision')); System.assert(false); }
            catch (AuraHandledException expected) { System.assert(expected.getMessage().contains('review manager')); }
            System.assertEquals(0,Limits.getCallouts()); System.assertEquals(0,Limits.getQueueableJobs());
        }
    }
    @IsTest static void supportTicketsRechecksManagerBeforeQueuedExecution() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Id conversationId=supportTicketsConversation(), managerId=configureReviewManager('accountId');
            Map<String,Object> review=read(Atlas_JiraWrites.prepareWrite(conversationId,JSON.serialize(bugRequest('manager-retires','accountId'))));
            Test.startTest();
            Atlas_JiraWrites.approveWrite((Id)review.get('id'),(String)review.get('revision'));
            update new Atlas_Person__c(Id=managerId,Active__c=false);
            Test.stopTest();
            System.assertEquals('invalidated',read(Atlas_JiraWrites.getWrite((Id)review.get('id'))).get('state'));
        }
    }
    static void saveProject(String project) {
        Atlas_Setting__c saved=[SELECT Id,Data__c FROM Atlas_Setting__c WHERE Key__c='jira'];
        Map<String,Object> settings=read(saved.Data__c); settings.put('projectKey',project); saved.Data__c=JSON.serialize(settings); update saved;
    }
    static void rejectBug(Id conversationId,Map<String,Object> request,String expectedText) {
        try { Atlas_JiraWrites.prepareWrite(conversationId,JSON.serialize(request)); System.assert(false,'Unexpectedly accepted '+JSON.serialize(request)); }
        catch (AuraHandledException expected) { System.assert(expected.getMessage().contains(expectedText),expected.getMessage()); }
    }
    @IsTest static void supportTicketsRequiresExactConfiguredProjectAndFieldShape() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Id conversationId=supportTicketsConversation(); configureReviewManager('accountId');
            for (Object project : new List<Object>{null,'DEMO',new Map<String,Object>{'key'=>'OTHER'},new Map<String,Object>{'key'=>'demo'},
                new Map<String,Object>{'id'=>'10000'},new Map<String,Object>{'key'=>'DEMO','name'=>'DEMO'}}) {
                Map<String,Object> request=bugRequest('project-shape','accountId'); ((Map<String,Object>)request.get('fields')).put('project',project);
                rejectBug(conversationId,request,'configured project key');
            }
            for (String field : new List<String>{'reporter','parent','customfield_10001','environment'}) {
                Map<String,Object> request=bugRequest('extra-'+field,'accountId'); ((Map<String,Object>)request.get('fields')).put(field,null);
                rejectBug(conversationId,request,'Unsupported Jira request property');
            }
            for (String project : new List<String>{null,'','invalid project','lowercase'}) {
                saveProject(project); rejectBug(conversationId,bugRequest('missing-project','accountId'),'valid Jira project key');
            }
            System.assertEquals(0,[SELECT count() FROM Atlas_Jira_Operation__c]);
            System.assertEquals(0,Limits.getCallouts()); System.assertEquals(0,Limits.getQueueableJobs());
        }
    }
    @IsTest static void supportTicketsRequiresEvidenceAndExactlyOneReviewLabel() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Id conversationId=supportTicketsConversation(); configureReviewManager('accountId');
            for (String field : new List<String>{'summary','description'}) for (Object invalid : new List<Object>{null,'','   ',42}) {
                Map<String,Object> request=bugRequest('empty-'+field,'accountId'); ((Map<String,Object>)request.get('fields')).put(field,invalid);
                rejectBug(conversationId,request,field);
            }
            for (Object labels : new List<Object>{null,'atlas-manager-review',new List<Object>(),new List<Object>{'atlas-manager-review','extra'},new List<Object>{'atlas-manager-review','atlas-manager-review'}}) {
                Map<String,Object> request=bugRequest('invalid-labels','accountId'); ((Map<String,Object>)request.get('fields')).put('labels',labels);
                rejectBug(conversationId,request,'exactly');
            }
            System.assertEquals(0,[SELECT count() FROM Atlas_Jira_Operation__c]);
        }
    }
    @IsTest static void supportTicketsValidatesOptionalPriorityAndDueDateWithoutDefaults() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Id conversationId=supportTicketsConversation(); configureReviewManager('accountId');
            for (Object priority : new List<Object>{null,'High',new Map<String,Object>(),new Map<String,Object>{'name'=>' '},new Map<String,Object>{'id'=>'1'},new Map<String,Object>{'name'=>'High','id'=>'1'}}) {
                Map<String,Object> request=bugRequest('bad-priority','accountId'); ((Map<String,Object>)request.get('fields')).put('priority',priority);
                rejectBug(conversationId,request,priority instanceof Map<String,Object> ? '' : 'priority');
            }
            for (Object due : new List<Object>{null,'','2026-02-30','2026-2-01','2026-10-19T00:00:00Z',42}) {
                Map<String,Object> request=bugRequest('bad-date','accountId'); ((Map<String,Object>)request.get('fields')).put('duedate',due);
                rejectBug(conversationId,request,'date');
            }
            Map<String,Object> request=bugRequest('with-options','accountId'), fields=(Map<String,Object>)request.get('fields');
            fields.put('priority',new Map<String,Object>{'name'=>'High'}); fields.put('duedate','2028-02-29');
            Map<String,Object> review=read(Atlas_JiraWrites.prepareWrite(conversationId,JSON.serialize(request)));
            Map<String,Object> sent=(Map<String,Object>)((Map<String,Object>)review.get('payload')).get('fields');
            System.assertEquals('High',((Map<String,Object>)sent.get('priority')).get('name')); System.assertEquals('2028-02-29',sent.get('duedate'));
            review=read(Atlas_JiraWrites.prepareWrite(conversationId,JSON.serialize(bugRequest('without-options','accountId'))));
            sent=(Map<String,Object>)((Map<String,Object>)review.get('payload')).get('fields');
            System.assertEquals(false,sent.containsKey('priority')); System.assertEquals(false,sent.containsKey('duedate'));
            System.assertEquals(0,Limits.getCallouts());
        }
    }
    @IsTest static void supportTicketsRechecksConfiguredProjectBeforeApproval() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Id conversationId=supportTicketsConversation(); configureReviewManager('accountId');
            Map<String,Object> review=read(Atlas_JiraWrites.prepareWrite(conversationId,JSON.serialize(bugRequest('project-approval','accountId'))));
            String fingerprint=Atlas_Jira.config().fingerprint; saveProject('OTHER');
            System.assertEquals(fingerprint,Atlas_Jira.config().fingerprint,'Project is not part of the connection fingerprint; the mode guard must recheck it.');
            try { Atlas_JiraWrites.approveWrite((Id)review.get('id'),(String)review.get('revision')); System.assert(false); }
            catch (AuraHandledException expected) { System.assert(expected.getMessage().contains('configured project key')); }
            System.assertEquals(0,Limits.getQueueableJobs()); System.assertEquals(0,Limits.getCallouts());
        }
    }
    @IsTest static void supportTicketsRechecksConfiguredProjectBeforeQueuedSend() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Id conversationId=supportTicketsConversation(); configureReviewManager('accountId');
            Map<String,Object> review=read(Atlas_JiraWrites.prepareWrite(conversationId,JSON.serialize(bugRequest('project-execution','accountId'))));
            Test.setMock(HttpCalloutMock.class,new MutationReply(201,'{"key":"DEMO-123"}'));
            Test.startTest(); Atlas_JiraWrites.approveWrite((Id)review.get('id'),(String)review.get('revision')); saveProject('OTHER'); Test.stopTest();
            System.assertEquals('invalidated',read(Atlas_JiraWrites.getWrite((Id)review.get('id'))).get('state'));
        }
    }
    @IsTest static void supportTicketsRejectsPreviouslyStoredBroadPayloadAtApprovalAndExecution() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Id ordinary=conversation(), investigation=supportTicketsConversation(); configureReviewManager('accountId');
            Map<String,Object> request=bugRequest('legacy-broad-approval','accountId');
            ((Map<String,Object>)request.get('fields')).put('reporter',new Map<String,Object>{'accountId'=>'other-person'});
            // Ordinary Task mode retains the broader API. Repointing its row in this test simulates
            // a Support Tickets review stored before the stricter validation was deployed.
            Map<String,Object> review=read(Atlas_JiraWrites.prepareWrite(ordinary,JSON.serialize(request)));
            update new Atlas_Jira_Operation__c(Id=(Id)review.get('id'),Conversation__c=investigation);
            try { Atlas_JiraWrites.approveWrite((Id)review.get('id'),(String)review.get('revision')); System.assert(false); }
            catch (AuraHandledException expected) { System.assert(expected.getMessage().contains('Unsupported Jira request property')); }
            request.put('requestId','legacy-broad-execution');
            review=read(Atlas_JiraWrites.prepareWrite(ordinary,JSON.serialize(request)));
            Test.setMock(HttpCalloutMock.class,new MutationReply(201,'{"key":"DEMO-123"}'));
            Test.startTest(); Atlas_JiraWrites.approveWrite((Id)review.get('id'),(String)review.get('revision'));
            update new Atlas_Jira_Operation__c(Id=(Id)review.get('id'),Conversation__c=investigation); Test.stopTest();
            System.assertEquals('invalidated',read(Atlas_JiraWrites.getWrite((Id)review.get('id'))).get('state'));
        }
    }
    @IsTest static void supportTicketsManualDraftCanBecomeReviewedLiveBugWithExplicitOptions() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Id conversationId=supportTicketsConversation(), manager=configureReviewManager('accountId');
            Atlas_Setting__c settingsRow=[SELECT Id,Data__c FROM Atlas_Setting__c WHERE Key__c='jira'];
            Map<String,Object> settings=read(settingsRow.Data__c); settings.put('writeEnabled',false); Atlas_Data.saveSetting('jira',JSON.serialize(settings));
            String batch=JSON.serialize(new Map<String,Object>{'projectKey'=>'DEMO','tickets'=>new List<Object>{new Map<String,Object>{
                'ref'=>'manual-bug','issueType'=>'Bug','summary'=>'Observed bug','description'=>'Administrator evidence for manager review.',
                'assigneeId'=>manager,'priority'=>'High','dueDate'=>'2028-02-29'}}});
            Atlas_Tickets.applyBatch(conversationId,Atlas_Tickets.prepareBatch(conversationId,batch));
            Id ticketId=[SELECT Id FROM Atlas_Ticket__c WHERE Conversation__c=:conversationId LIMIT 1].Id;
            settings.put('writeEnabled',true); Atlas_Data.saveSetting('jira',JSON.serialize(settings));
            Map<String,Object> review=read(Atlas_JiraWrites.prepareTicketWrite(ticketId,'create',null,Atlas_Tickets.getTicket(ticketId).version));
            Map<String,Object> fields=(Map<String,Object>)((Map<String,Object>)review.get('payload')).get('fields');
            System.assertEquals(new Set<String>{'project','issuetype','summary','description','assignee','labels','priority','duedate'},fields.keySet());
            System.assertEquals('High',((Map<String,Object>)fields.get('priority')).get('name')); System.assertEquals('2028-02-29',fields.get('duedate'));
            System.assertEquals('manager-jira-id',((Map<String,Object>)fields.get('assignee')).get('accountId'));
            System.assertEquals(0,Limits.getCallouts()); System.assertEquals(0,Limits.getQueueableJobs());
            Test.setMock(HttpCalloutMock.class,new MutationReply(201,'{"key":"DEMO-123"}'));
            Test.startTest(); Atlas_JiraWrites.approveWrite((Id)review.get('id'),(String)review.get('revision')); Test.stopTest();
            System.assertEquals('succeeded',read(Atlas_JiraWrites.getWrite((Id)review.get('id'))).get('state'));
        }
    }
    @IsTest static void supportTicketsLocalConversionRejectsForbiddenFieldsWithoutDroppingThem() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Id conversationId=supportTicketsConversation(), manager=configureReviewManager('accountId');
            Atlas_Ticket__c ticket=new Atlas_Ticket__c(Summary__c='Bug draft',Description__c='Evidence',Issue_Type__c='Bug',Project_Key__c='DEMO',
                Stage__c='Draft',Conversation__c=conversationId,Assignee__c=manager); insert ticket;
            for (String field : new List<String>{'Reporter__c','Epic_Key__c','Planning__c','Due_Date_Source__c'}) {
                ticket.Reporter__c=null; ticket.Epic_Key__c=null; ticket.Planning__c=null; ticket.Due_Date__c=null; ticket.Due_Date_Source__c=null;
                if (field=='Reporter__c') ticket.Reporter__c=manager;
                if (field=='Epic_Key__c') ticket.Epic_Key__c='DEMO-42';
                if (field=='Planning__c') ticket.Planning__c='{"customFields":{"customfield_123":"keep"}}';
                if (field=='Due_Date_Source__c') { ticket.Due_Date__c=Date.newInstance(2028,2,29); ticket.Due_Date_Source__c='suggested'; }
                update ticket;
                try { Atlas_JiraWrites.prepareTicketWrite(ticket.Id,'create',null,Atlas_Tickets.getTicket(ticket.Id).version); System.assert(false,field); }
                catch (AuraHandledException expected) { System.assert(expected.getMessage().contains('manual export'),expected.getMessage()); }
            }
            System.assertEquals(0,Limits.getCallouts()); System.assertEquals(0,[SELECT count() FROM Atlas_Jira_Operation__c]);
        }
    }
    @IsTest static void uatBlocksDirectJiraRequestsAndSavedApprovals() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Id uatId=(Id)Atlas_Data.saveConversation(JSON.serialize(new Map<String,Object>{'title'=>'QA-only plan','mode'=>'uat','request'=>'Test the checkout flow.',
                'uat'=>new Map<String,Object>{'componentType'=>'Flow','apiName'=>'Order_Flow','goal'=>'Verify valid and invalid orders.','testing'=>''}}));
            try { Atlas_JiraWrites.prepareWrite(uatId,createRequest('uat-direct')); System.assert(false); }
            catch (AuraHandledException expected) { System.assert(expected.getMessage().contains('UAT')); }
            System.assertEquals(0,[SELECT count() FROM Atlas_Jira_Operation__c]);

            Id taskId=[SELECT Id FROM Atlas_Conversation__c WHERE Mode__c='Task' LIMIT 1].Id;
            Atlas_Jira.inspector=new Atlas_JiraTest.Credentials();
            Map<String,Object> review=read(Atlas_JiraWrites.prepareWrite(taskId,createRequest('uat-stale-review')));
            update new Atlas_Jira_Operation__c(Id=(Id)review.get('id'),Conversation__c=uatId);
            try { Atlas_JiraWrites.approveWrite((Id)review.get('id'),(String)review.get('revision')); System.assert(false); }
            catch (AuraHandledException expected) { System.assert(expected.getMessage().contains('UAT')); }
            System.assertEquals('reviewed',read(Atlas_JiraWrites.getWrite((Id)review.get('id'))).get('state'));
            System.assertEquals(0,Limits.getCallouts()); System.assertEquals(0,Limits.getQueueableJobs());
        }
    }
    @IsTest static void uatPersistedModeIsRecheckedByQueuedJiraWorker() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Map<String,Object> review=prepare(createRequest('uat-queued-recheck'));
            Id operationId=(Id)review.get('id'), conversationId=conversation();
            Test.setMock(HttpCalloutMock.class,new MutationReply(201,'{"key":"DEMO-123"}'));
            Test.startTest();
            Atlas_JiraWrites.approveWrite(operationId,(String)review.get('revision'));
            update new Atlas_Conversation__c(Id=conversationId,Mode__c='uat');
            Test.stopTest();
            System.assertEquals('invalidated',read(Atlas_JiraWrites.getWrite(operationId)).get('state'),
                'The queued writer must consult the latest persisted conversation mode before calling Jira.');
        }
    }
    @IsTest static void exactReviewApprovalAndLostResponseReplay() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Map<String,Object> review=prepare(createRequest('stable-1'));
            System.assertEquals('reviewed',review.get('state')); System.assertEquals(0,Limits.getCallouts());
            System.assertEquals(review.get('id'),prepare(createRequest('stable-1')).get('id'));
            System.assert(JSON.serialize(review.get('payload')).contains('"type":"doc"'));
            Test.setMock(HttpCalloutMock.class,new MutationReply(201,'{"id":"123","key":"DEMO-123","self":"https://secret.example/?token=SECRET"}'));
            Test.startTest();
            Map<String,Object> queued=read(Atlas_JiraWrites.approveWrite((Id)review.get('id'),(String)review.get('revision')));
            System.assertEquals('queued',queued.get('state'));
            Atlas_JiraWrites.approveWrite((Id)review.get('id'),(String)review.get('revision'));
            System.assertEquals(1,Limits.getQueueableJobs());
            Test.stopTest();
            Map<String,Object> done=read(Atlas_JiraWrites.getWrite((Id)review.get('id')));
            System.assertEquals('succeeded',done.get('state'));
            System.assertEquals('DEMO-123',((Map<String,Object>)done.get('result')).get('issueKey'));
            System.assert(!JSON.serialize(done).contains('SECRET'));
            System.assertEquals('succeeded',read(Atlas_JiraWrites.approveWrite((Id)review.get('id'),(String)review.get('revision'))).get('state'));
            System.assertEquals(1,((List<Object>)JSON.deserializeUntyped(Atlas_JiraWrites.listWrites(conversation()))).size());
        }
    }
    @IsTest static void payloadChangesCannotReuseReceiptOrApproval() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Map<String,Object> review=prepare(createRequest('stable-2'));
            try { prepare(createRequest('stable-2').replace('Exact reviewed summary','Different summary')); System.assert(false); }
            catch (AuraHandledException expected) { System.assert(expected.getMessage().contains('different reviewed content')); }
            try { Atlas_JiraWrites.approveWrite((Id)review.get('id'),'wrong'); System.assert(false); }
            catch (AuraHandledException expected) { System.assert(expected.getMessage().contains('review changed')); }
            System.assertEquals(0,Limits.getQueueableJobs());
        }
    }
    @IsTest static void disabledWritesAndConfigChangeInvalidateUnsentReview() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Map<String,Object> review=prepare(createRequest('config-change'));
            Atlas_JiraTest.settings(true,false,'3');
            Map<String,Object> state=read(Atlas_JiraWrites.approveWrite((Id)review.get('id'),(String)review.get('revision')));
            System.assertEquals('invalidated',state.get('state')); System.assertEquals(0,Limits.getQueueableJobs());
            try { prepare(createRequest('readonly')); System.assert(false); }
            catch (AuraHandledException expected) { System.assert(expected.getMessage().contains('disabled')); }
        }
    }
    @IsTest static void executionRechecksSwitchesAfterApprovalCommitted() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Map<String,Object> review=prepare(createRequest('queued-change'));
            Test.startTest();
            Atlas_JiraWrites.approveWrite((Id)review.get('id'),(String)review.get('revision'));
            Atlas_JiraTest.settings(true,false,'3');
            Test.stopTest();
            System.assertEquals('invalidated',read(Atlas_JiraWrites.getWrite((Id)review.get('id'))).get('state'));
        }
    }
    @IsTest static void timeoutIsUnknownAndNeverResent() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Map<String,Object> review=prepare(createRequest('timeout'));
            Test.setMock(HttpCalloutMock.class,new MutationReply(true));
            Test.startTest(); Atlas_JiraWrites.approveWrite((Id)review.get('id'),(String)review.get('revision')); Test.stopTest();
            Map<String,Object> result=read(Atlas_JiraWrites.getWrite((Id)review.get('id')));
            System.assertEquals('unknown',result.get('state')); System.assert(!JSON.serialize(result).contains('SECRET'));
            System.assertEquals('unknown',read(Atlas_JiraWrites.approveWrite((Id)review.get('id'),(String)review.get('revision'))).get('state'));
        }
    }
    @IsTest static void serverErrorIsUnknownNotFailed() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Map<String,Object> review=prepare(createRequest('server-error'));
            Test.setMock(HttpCalloutMock.class,new MutationReply(503,'SECRET'));
            Test.startTest(); Atlas_JiraWrites.approveWrite((Id)review.get('id'),(String)review.get('revision')); Test.stopTest();
            System.assertEquals('unknown',read(Atlas_JiraWrites.getWrite((Id)review.get('id'))).get('state'));
        }
    }
    @IsTest static void misleadingSuccessDoesNotClaimCreation() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Map<String,Object> review=prepare(createRequest('false-success'));
            Test.setMock(HttpCalloutMock.class,new MutationReply(200,'{"ok":true}'));
            Test.startTest(); Atlas_JiraWrites.approveWrite((Id)review.get('id'),(String)review.get('revision')); Test.stopTest();
            System.assertEquals('unknown',read(Atlas_JiraWrites.getWrite((Id)review.get('id'))).get('state'));
        }
    }
    @IsTest static void explicitRejectionIsFailedAndPrivate() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Map<String,Object> review=prepare(createRequest('forbidden'));
            Test.setMock(HttpCalloutMock.class,new MutationReply(403,'{"error":"SECRET"}'));
            Test.startTest(); Atlas_JiraWrites.approveWrite((Id)review.get('id'),(String)review.get('revision')); Test.stopTest();
            String result=Atlas_JiraWrites.getWrite((Id)review.get('id'));
            System.assertEquals('failed',read(result).get('state')); System.assert(!result.contains('SECRET'));
        }
    }
    @IsTest static void missingWorkerReceiptBecomesPersistedUnknown() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Map<String,Object> review=prepare(createRequest('lost-persistence'));
            Id operationId=(Id)review.get('id');
            // Simulates a transaction failure after the external callout: the approved record remains queued.
            update new Atlas_Jira_Operation__c(Id=operationId,State__c='queued',Job_Id__c='707000000000001');
            System.assertEquals('unknown',read(Atlas_JiraWrites.getWrite(operationId)).get('state'));
            System.assertEquals('unknown',[SELECT State__c FROM Atlas_Jira_Operation__c WHERE Id=:operationId].State__c);
            Atlas_JiraWrites.approveWrite(operationId,(String)review.get('revision'));
            System.assertEquals(0,Limits.getQueueableJobs());
        }
    }
    @IsTest static void malformedPayloadsAreBlockedBeforeApproval() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Jira.Config c=Atlas_Jira.config();
            for (String request : new List<String>{
                '{"requestId":"bad","operation":"delete","issueKey":"DEMO-1"}',
                '{"requestId":"bad","operation":"update","issueKey":"DEMO-1","fields":{"status":{"name":"Done"}}}',
                '{"requestId":"bad","operation":"comment","issueKey":"DEMO-1","body":{"type":"doc"}}',
                '{"requestId":"bad","operation":"transition","issueKey":"DEMO-1","transitionId":"../admin"}',
                '{"requestId":"bad","operation":"comment","issueKey":"DEMO-1","body":"safe","headers":{"Authorization":"SECRET"}}',
                '{"requestId":"bad","operation":"update","issueKey":"DEMO-1","fields":{"description":{"type":"doc"}}}'}) {
                try { Atlas_JiraWrites.mutation(read(request),c); System.assert(false,request); }
                catch (Atlas_Api.AtlasException expected) { System.assert(!expected.getMessage().contains('SECRET')); }
            }
            System.assertEquals(0,Limits.getCallouts());
            System.assertEquals('PUT',Atlas_JiraWrites.mutation(read('{"requestId":"ok","operation":"update","issueKey":"DEMO-1","fields":{"summary":"new"}}'),c).method);
            System.assert(Atlas_JiraWrites.mutation(read('{"requestId":"ok","operation":"comment","issueKey":"DEMO-1","body":"Text"}'),c).payload.contains('"type":"doc"'));
            System.assert(Atlas_JiraWrites.mutation(read('{"requestId":"ok","operation":"transition","issueKey":"DEMO-1","transitionId":"11"}'),c).path.endsWith('/transitions'));
            c.apiVersion='2'; System.assertEquals('{"body":"Text"}',Atlas_JiraWrites.mutation(read('{"requestId":"ok","operation":"comment","issueKey":"DEMO-1","body":"Text"}'),c).payload);
        }
    }
    @IsTest static void draftCreateSynchronizesOnlyAfterJiraConfirmation() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Jira.inspector=new Atlas_JiraTest.Credentials();
            Id ticketId=[SELECT Id FROM Atlas_Ticket__c LIMIT 1].Id;
            String version=Atlas_Tickets.getTicket(ticketId).version;
            Map<String,Object> review=read(Atlas_JiraWrites.prepareTicketWrite(ticketId,'create',null,version));
            System.assertEquals('Draft',[SELECT Stage__c FROM Atlas_Ticket__c WHERE Id=:ticketId].Stage__c);
            Test.setMock(HttpCalloutMock.class,new MutationReply(201,'{"key":"DEMO-123"}'));
            Test.startTest(); Atlas_JiraWrites.approveWrite((Id)review.get('id'),(String)review.get('revision')); Test.stopTest();
            Map<String,Object> outcome=read(Atlas_JiraWrites.getWrite((Id)review.get('id')));
            System.assertEquals('succeeded',outcome.get('state')); System.assertEquals(true,((Map<String,Object>)outcome.get('result')).get('mirrorSynced'));
            Atlas_Ticket__c ticket=[SELECT Jira_Key__c,Stage__c FROM Atlas_Ticket__c WHERE Id=:ticketId];
            System.assertEquals('DEMO-123',ticket.Jira_Key__c); System.assertEquals('In Jira',ticket.Stage__c);
        }
    }
    static Id pendingTicket() {
        Atlas_Ticket__c ticket=new Atlas_Ticket__c(Summary__c='Old summary',Project_Key__c='DEMO',Issue_Type__c='Task',Stage__c='In Jira',Jira_Key__c='DEMO-9',
            Pending_Updates__c='[{"id":"U1","status":"pending","changes":{"summary":"New summary"},"baseline":{"summary":"Old summary"},"fieldStatus":{},"comments":[{"text":"Reviewed comment","status":"pending"}]}]');
        insert ticket; return ticket.Id;
    }
    @IsTest static void unknownCreateCannotBeRepeatedByCsvOrNewReview() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Jira.inspector=new Atlas_JiraTest.Credentials();
            Id ticketId=[SELECT Id FROM Atlas_Ticket__c LIMIT 1].Id;
            String version=Atlas_Tickets.getTicket(ticketId).version;
            Map<String,Object> review=read(Atlas_JiraWrites.prepareTicketWrite(ticketId,'create',null,version));
            for (String state : new List<String>{'queued','unknown','succeeded'}) {
                update new Atlas_Jira_Operation__c(Id=(Id)review.get('id'),State__c=state);
                try {
                    Atlas_Tickets.saveExport(JSON.serialize(new Map<String,Object>{'versions'=>new Map<Id,Object>{ticketId=>version},'phase'=>'children','csv'=>'Summary\nDraft for Jira'}));
                    System.assert(false,state);
                } catch (AuraHandledException expected) { System.assert(expected.getMessage().contains('live Jira operation')); }
            }
            update new Atlas_Ticket__c(Id=ticketId,Summary__c='Changed locally');
            try { Atlas_JiraWrites.prepareTicketWrite(ticketId,'create',null,Atlas_Tickets.getTicket(ticketId).version); System.assert(false); }
            catch (AuraHandledException expected) { System.assert(expected.getMessage().contains('saved Jira operation')); }
        }
    }
    @IsTest static void manualExportAfterReviewInvalidatesApproval() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Jira.inspector=new Atlas_JiraTest.Credentials();
            Id ticketId=[SELECT Id FROM Atlas_Ticket__c LIMIT 1].Id;
            String version=Atlas_Tickets.getTicket(ticketId).version;
            Map<String,Object> review=read(Atlas_JiraWrites.prepareTicketWrite(ticketId,'create',null,version));
            Atlas_Tickets.saveExport(JSON.serialize(new Map<String,Object>{'versions'=>new Map<Id,Object>{ticketId=>version},'phase'=>'children','batch'=>'manual','csv'=>'Summary\nDraft for Jira','jiraIds'=>new Map<String,Object>()}));
            try { Atlas_JiraWrites.approveWrite((Id)review.get('id'),(String)review.get('revision')); System.assert(false); }
            catch (AuraHandledException expected) { System.assert(expected.getMessage().contains('ticket changed')); }
            System.assertEquals(0,Limits.getQueueableJobs());
        }
    }
    @IsTest static void uncertainFieldAndCommentCannotBeManuallyConfirmedOrDismissed() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Jira.inspector=new Atlas_JiraTest.Credentials();
            Id ticketId=pendingTicket(); String version=Atlas_Tickets.getTicket(ticketId).version;
            for (String part : new List<String>{'field:summary','comment:0'}) {
                Map<String,Object> review=read(Atlas_JiraWrites.prepareTicketWrite(ticketId,part,'U1',version));
                for (String state : new List<String>{'queued','unknown','succeeded'}) {
                    update new Atlas_Jira_Operation__c(Id=(Id)review.get('id'),State__c=state);
                    try { Atlas_Tickets.completeUpdatePart(ticketId,'U1',part,true,version); System.assert(false,state); }
                    catch (AuraHandledException expected) { System.assert(expected.getMessage().contains('live Jira operation')); }
                }
            }
            try { Atlas_Tickets.completeUpdatePart(ticketId,'U1','dismiss',false,version); System.assert(false); }
            catch (AuraHandledException expected) { System.assert(expected.getMessage().contains('live Jira operation')); }
        }
    }
    class PartReply implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            System.assertEquals('PUT',request.getMethod()); System.assert(request.getEndpoint().endsWith('/issue/DEMO-9'));
            System.assertEquals('{"fields":{"summary":"New summary"}}',request.getBody());
            HttpResponse response=new HttpResponse(); response.setStatusCode(204); response.setBody(''); return response;
        }
    }
    @IsTest static void confirmedLiveFieldSynchronizesThroughItsOwnReservation() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Jira.inspector=new Atlas_JiraTest.Credentials();
            Id ticketId=pendingTicket();
            Map<String,Object> review=read(Atlas_JiraWrites.prepareTicketWrite(ticketId,'field:summary','U1',Atlas_Tickets.getTicket(ticketId).version));
            Test.setMock(HttpCalloutMock.class,new PartReply());
            Test.startTest(); Atlas_JiraWrites.approveWrite((Id)review.get('id'),(String)review.get('revision')); Test.stopTest();
            Map<String,Object> done=read(Atlas_JiraWrites.getWrite((Id)review.get('id')));
            System.assertEquals('succeeded',done.get('state')); System.assertEquals(true,((Map<String,Object>)done.get('result')).get('mirrorSynced'));
            System.assertEquals('New summary',Atlas_Tickets.getTicket(ticketId).summary);
        }
    }
    class LegacyCommentReply implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            System.assertEquals('POST',request.getMethod());
            System.assertEquals('callout:Any_Jira_Connection/rest/api/3/issue/DEMO-9/comment',request.getEndpoint());
            System.assertEquals(read('{"body":{"type":"doc","version":1,"content":[{"type":"paragraph","content":[{"type":"text","text":"Legacy reviewed comment"}]}]}}'),read(request.getBody()));
            Atlas_Jira_Operation__c operation=[SELECT Payload__c,Job_Id__c FROM Atlas_Jira_Operation__c WHERE State__c='queued' LIMIT 1];
            System.assertNotEquals(null,operation.Job_Id__c);
            System.assertEquals(operation.Payload__c,request.getBody());
            HttpResponse response=new HttpResponse(); response.setStatusCode(201); response.setBody('{"id":"1001"}'); return response;
        }
    }
    @IsTest static void legacyStringCommentCanBeReviewedAndConfirmedLive() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Jira.inspector=new Atlas_JiraTest.Credentials();
            String history='[{"id":"U1","status":"pending","changes":{},"fieldStatus":{},"comments":["Legacy reviewed comment"]}]';
            Atlas_Ticket__c ticket=new Atlas_Ticket__c(Summary__c='Legacy comment',Project_Key__c='DEMO',Issue_Type__c='Task',Stage__c='In Jira',Jira_Key__c='DEMO-9',Pending_Updates__c=history);
            insert ticket;
            Map<String,Object> review=read(Atlas_JiraWrites.prepareTicketWrite(ticket.Id,'comment:0','U1',Atlas_Tickets.getTicket(ticket.Id).version));
            System.assertEquals('reviewed',review.get('state'));
            System.assertEquals('comment',review.get('operation'));
            System.assertEquals(history,[SELECT Pending_Updates__c FROM Atlas_Ticket__c WHERE Id=:ticket.Id].Pending_Updates__c);
            Test.setMock(HttpCalloutMock.class,new LegacyCommentReply());
            Test.startTest(); Atlas_JiraWrites.approveWrite((Id)review.get('id'),(String)review.get('revision')); Test.stopTest();
            Map<String,Object> done=read(Atlas_JiraWrites.getWrite((Id)review.get('id')));
            System.assertEquals('succeeded',done.get('state'));
            System.assertEquals(true,((Map<String,Object>)done.get('result')).get('mirrorSynced'));
            System.assertEquals('1001',((Map<String,Object>)done.get('result')).get('commentId'));
            Atlas_Tickets.Ticket saved=Atlas_Tickets.getTicket(ticket.Id);
            Map<String,Object> updateItem=(Map<String,Object>)saved.pendingUpdates[0];
            Map<String,Object> comment=(Map<String,Object>)((List<Object>)updateItem.get('comments'))[0];
            System.assertEquals('Legacy reviewed comment',comment.get('text'));
            System.assertEquals('done',comment.get('status'));
            System.assertEquals('done',updateItem.get('status'));
            System.assertEquals(0,saved.pendingCount);
        }
    }
    @IsTest static void operationListsAreSummariesAndDestinationsAreImmutable() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Map<String,Object> review=prepare(createRequest('destination'));
            System.assertEquals('https://jira.example',review.get('apiBaseUrl')); System.assertEquals('Any_Jira_Connection',review.get('namedCredential'));
            List<Object> rows=(List<Object>)JSON.deserializeUntyped(Atlas_JiraWrites.listWrites(conversation()));
            Map<String,Object> summary=(Map<String,Object>)rows[0]; System.assertEquals(true,summary.get('summary'));
            System.assert(!summary.containsKey('payload')); System.assert(!summary.containsKey('result')); System.assert(!summary.containsKey('request'));
            Atlas_JiraTest.settings(true,false,'2');
            Map<String,Object> saved=read(Atlas_JiraWrites.getWrite((Id)review.get('id')));
            System.assertEquals('3',saved.get('apiVersion'));
        }
    }
    @IsTest static void exactSourceFingerprintProtectsDescriptionAndPendingContent() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Jira.inspector=new Atlas_JiraTest.Credentials();
            Id ticketId=pendingTicket();
            Map<String,Object> prepared=Atlas_Tickets.prepareLiveWrite(ticketId,'field:summary','U1',Atlas_Tickets.getTicket(ticketId).version);
            Map<String,Object> context=(Map<String,Object>)prepared.get('context');
            System.assertNotEquals(null,context.get('sourceFingerprint'));
            update new Atlas_Ticket__c(Id=ticketId,Description__c='Changed outside the UI');
            // Even if the coarse/version-only check were to pass, the exact reviewed source cannot.
            context.put('version',Atlas_Tickets.getTicket(ticketId).version);
            try { Atlas_Tickets.checkLiveWriteContext(context,true); System.assert(false); }
            catch (Atlas_Api.AtlasException expected) { System.assert(expected.getMessage().contains('exact ticket description or proposal')); }
            prepared=Atlas_Tickets.prepareLiveWrite(ticketId,'field:summary','U1',Atlas_Tickets.getTicket(ticketId).version);
            context=(Map<String,Object>)prepared.get('context');
            Atlas_Ticket__c row=[SELECT Pending_Updates__c FROM Atlas_Ticket__c WHERE Id=:ticketId];
            row.Pending_Updates__c=row.Pending_Updates__c.replace('New summary','Different proposed summary'); update row;
            context.put('version',Atlas_Tickets.getTicket(ticketId).version);
            try { Atlas_Tickets.checkLiveWriteContext(context,false); System.assert(false); }
            catch (Atlas_Api.AtlasException expected) { System.assert(expected.getMessage().contains('exact ticket description or proposal')); }
        }
    }
    class ChangingCredentials extends Atlas_Jira.CredentialInspector {
        Id ticketId;
        ChangingCredentials(Id ticketId) { this.ticketId=ticketId; }
        public override Map<String,Object> inspect(String name) {
            update new Atlas_Ticket__c(Id=ticketId,Description__c='Changed while metadata was read');
            return new Atlas_JiraTest.Credentials().inspect(name);
        }
    }
    @IsTest static void finalPreparationLockRejectsChangesDuringMetadataReads() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Id ticketId=[SELECT Id FROM Atlas_Ticket__c LIMIT 1].Id;
            Atlas_Jira.inspector=new ChangingCredentials(ticketId);
            try { Atlas_JiraWrites.prepareTicketWrite(ticketId,'create',null,Atlas_Tickets.getTicket(ticketId).version); System.assert(false); }
            catch (AuraHandledException expected) { System.assert(expected.getMessage().contains('changed')); }
            System.assertEquals(0,[SELECT COUNT() FROM Atlas_Jira_Operation__c]);
        }
    }
    @IsTest static void changedTicketInvalidatesBeforeSending() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Jira.inspector=new Atlas_JiraTest.Credentials();
            Id ticketId=[SELECT Id FROM Atlas_Ticket__c LIMIT 1].Id;
            Map<String,Object> review=read(Atlas_JiraWrites.prepareTicketWrite(ticketId,'create',null,Atlas_Tickets.getTicket(ticketId).version));
            Test.startTest();
            Atlas_JiraWrites.approveWrite((Id)review.get('id'),(String)review.get('revision'));
            update new Atlas_Ticket__c(Id=ticketId,Summary__c='Changed after review');
            Test.stopTest();
            System.assertEquals('invalidated',read(Atlas_JiraWrites.getWrite((Id)review.get('id'))).get('state'));
            System.assertEquals(null,[SELECT Jira_Key__c FROM Atlas_Ticket__c WHERE Id=:ticketId].Jira_Key__c);
        }
    }
}
