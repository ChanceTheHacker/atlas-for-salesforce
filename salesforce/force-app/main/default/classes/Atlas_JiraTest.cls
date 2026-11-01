@IsTest
public class Atlas_JiraTest {
    public class Credentials extends Atlas_Jira.CredentialInspector {
        public Boolean mismatch=false;
        public override Map<String,Object> inspect(String name) {
            System.assertEquals('Any_Jira_Connection',name);
            return new Map<String,Object>{'calloutUrl'=>mismatch ? 'https://other.example' : 'https://jira.example',
                'externalCredentials'=>new List<Object>{new Map<String,Object>{'developerName'=>'Any_Jira_Authentication'}}};
        }
    }
    public static void configurePermission() {
        Id userId=UserInfo.getUserId();
        String fullName=Atlas_Setting__c.SObjectType.getDescribe().getName();
        String prefix=fullName.substring(0,fullName.length()-'Atlas_Setting__c'.length());
        String namespaceValue=String.isBlank(prefix) ? null : prefix.removeEnd('__');
        Id permissionId=[SELECT Id FROM PermissionSet WHERE Name='Atlas_Jira_Admin' AND NamespacePrefix=:namespaceValue LIMIT 1].Id;
        if ([SELECT COUNT() FROM PermissionSetAssignment WHERE AssigneeId=:userId AND PermissionSetId=:permissionId]==0) {
            System.runAs(new User(Id=userId)) { insert new PermissionSetAssignment(AssigneeId=userId,PermissionSetId=permissionId); }
        }
    }
    public static void settings(Boolean reads,Boolean writes,String version) {
        configurePermission();
        Atlas_Jira.inspector=new Credentials();
        // Permission checks cache per runAs context; enter only after the assignment exists.
        System.runAs(new User(Id=UserInfo.getUserId())) {
            System.assert(Atlas_Jira.canConfigure(),'Jira Admin assignment must grant the namespaced configure permission; unqualified=' + FeatureManagement.checkPermission('Atlas_Configure_Jira'));
            Atlas_Data.saveSetting('jira',JSON.serialize(new Map<String,Object>{'siteUrl'=>'https://jira.example','apiBaseUrl'=>'https://jira.example',
                'namedCredential'=>'Any_Jira_Connection','externalCredential'=>'Any_Jira_Authentication','apiVersion'=>version,'readEnabled'=>reads,'writeEnabled'=>writes}));
        }
    }
    public class Reply implements HttpCalloutMock {
        public String expectedPath, expectedMethod, body;
        public Integer status;
        public Reply(String path,String method,Integer status,String body) { this.expectedPath=path; this.expectedMethod=method; this.status=status; this.body=body; }
        public HttpResponse respond(HttpRequest req) {
            System.assert(req.getEndpoint().startsWith('callout:Any_Jira_Connection/rest/api/'),req.getEndpoint());
            System.assert(req.getEndpoint().contains(expectedPath),req.getEndpoint());
            System.assertEquals(expectedMethod,req.getMethod());
            System.assertEquals(null,req.getHeader('Authorization'));
            if (expectedPath.contains('/search')) {
                Map<String,Object> payload=(Map<String,Object>)JSON.deserializeUntyped(req.getBody());
                System.assertEquals(25,payload.get('maxResults'));
                System.assert(!payload.containsKey('url'));
            }
            HttpResponse response=new HttpResponse(); response.setStatusCode(status); response.setBody(body); return response;
        }
    }
    @IsTest static void manualFallbackAndStrictSettings() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Map<String,Object> caps=(Map<String,Object>)JSON.deserializeUntyped(Atlas_Jira.capabilities());
            System.assertEquals(false,caps.get('connected'));
            System.assert(Atlas_Research.run('{"op":"tickets","owner":"everyone"}').contains('tickets'));
            for (String invalid : new List<String>{'{"readEnabled":"false"}','{"apiToken":"never-save"}','{"nested":{"password":"never-save"}}','{"externalCredential":"Only_One"}','{"namedCredential":"Only_One"}','{"siteUrl":"https://user:password@jira.example"}'}) {
                try { Atlas_Data.saveSetting('jira',invalid); System.assert(false,invalid); }
                catch (AuraHandledException expected) { System.assert(!expected.getMessage().contains('never-save')); }
            }
            Atlas_Data.saveSetting('jira','{"projectKey":"DEMO","siteUrl":"https://jira.example"}');
            System.assertEquals(false,Atlas_Jira.config().connected);
        }
    }
    @IsTest static void cloudEnhancedSearchAndSafeOutput() {
        System.runAs(Atlas_Mock.atlasUser()) {
            settings(true,false,'3');
            Test.setMock(HttpCalloutMock.class,new Reply('/rest/api/3/search/jql','POST',200,
                '{"issues":[{"id":"1","key":"DEMO-1","self":"https://secret.example","fields":{"summary":"Hello","assignee":{"accountId":"a","displayName":"Alex","emailAddress":"private@example.com","accessToken":"SECRET"}}}],"isLast":false,"nextPageToken":"page2"}'));
            Test.startTest();
            String output=Atlas_Research.run('{"op":"jira","action":"search","jql":"project=DEMO"}');
            Test.stopTest();
            Map<String,Object> response=(Map<String,Object>)JSON.deserializeUntyped(output);
            System.assertEquals('live-jira',response.get('source')); System.assertEquals(true,response.get('authoritative'));
            System.assertEquals('page2',response.get('nextPageToken')); System.assertEquals(true,response.get('hasMore'));
            System.assert(!output.contains('SECRET')); System.assert(!output.contains('private@example')); System.assert(!output.contains('secret.example'));
        }
    }
    @IsTest static void dataCenterAndExplicitMirror() {
        System.runAs(Atlas_Mock.atlasUser()) {
            settings(true,false,'2');
            Test.startTest();
            Test.setMock(HttpCalloutMock.class,new Reply('/rest/api/2/search','POST',200,'{"issues":[],"startAt":0,"total":0}'));
            Map<String,Object> result=Atlas_Jira.run(new Map<String,Object>{'action'=>'search','jql'=>'project=DEMO','startAt'=>0});
            System.assertEquals(false,result.get('hasMore'));
            System.assert(Atlas_Research.run('{"op":"local-tickets","owner":"everyone"}').contains('tickets'));
            try { Atlas_Jira.run(new Map<String,Object>{'action'=>'search','jql'=>'project=DEMO','nextPageToken'=>'wrong'}); System.assert(false); }
            catch (Atlas_Api.AtlasException expected) { System.assert(expected.getMessage().contains('startAt')); }
            Test.stopTest();
        }
    }
    @IsTest static void disabledReadsNeverUseMirror() {
        System.runAs(Atlas_Mock.atlasUser()) {
            settings(false,true,'3');
            Integer before=Limits.getCallouts();
            try { Atlas_Research.run('{"op":"tickets","owner":"everyone"}'); System.assert(false); }
            catch (AuraHandledException expected) { System.assert(expected.getMessage().contains('disabled')); }
            try { Atlas_Jira.connectionTest(); System.assert(false); }
            catch (AuraHandledException expected) { System.assert(expected.getMessage().contains('disabled')); }
            System.assertEquals(before,Limits.getCallouts());
        }
    }
    @IsTest static void readErrorsAreAuthoritativeAndDoNotLeakBodies() {
        System.runAs(Atlas_Mock.atlasUser()) {
            settings(true,false,'3');
            Test.startTest();
            Test.setMock(HttpCalloutMock.class,new Reply('/issue/DEMO-1','GET',403,'{"error":"Authorization Bearer SECRET"}'));
            try { Atlas_Research.run('{"op":"jira","action":"issue","issueKey":"DEMO-1"}'); System.assert(false); }
            catch (AuraHandledException expected) {
                System.assert(expected.getMessage().contains('403')); System.assert(!expected.getMessage().contains('SECRET')); System.assert(expected.getMessage().contains('not substituted'));
            }
            for (String invalid : new List<String>{'{"action":"issue","issueKey":"../admin"}','{"action":"issue","issueKey":"DEMO-1","headers":{}}','{"action":"search","jql":"x","maxResults":51}','{"action":"search","jql":"x","startAt":1}'}) {
                try { Atlas_Jira.run((Map<String,Object>)JSON.deserializeUntyped(invalid)); System.assert(false,invalid); }
                catch (Atlas_Api.AtlasException expected) { System.assertNotEquals(null,expected.getMessage()); }
            }
            Test.stopTest();
        }
    }
    @IsTest static void credentialEndpointMustMatch() {
        System.runAs(Atlas_Mock.atlasUser()) {
            settings(true,false,'3');
            Credentials bad=new Credentials(); bad.mismatch=true; Atlas_Jira.inspector=bad;
            try { Atlas_Jira.run(new Map<String,Object>{'action'=>'issue','issueKey'=>'DEMO-1'}); System.assert(false); }
            catch (Atlas_Api.AtlasException expected) { System.assert(expected.getMessage().contains('Cannot verify')); }
            System.assertEquals(0,Limits.getCallouts());
        }
    }
    @IsTest static void connectionTestMustRecognizeJiraIdentity() {
        System.runAs(Atlas_Mock.atlasUser()) {
            settings(true,true,'3');
            Test.startTest();
            Test.setMock(HttpCalloutMock.class,new Reply('/myself','GET',200,'{"accountId":"redacted","emailAddress":"private@example.com","accessToken":"SECRET"}'));
            String response=Atlas_Jira.connectionTest();
            System.assert(response.contains('writePermissionVerified')); System.assert(!response.contains('SECRET')); System.assert(!response.contains('redacted'));
            Test.setMock(HttpCalloutMock.class,new Reply('/myself','GET',200,'{"ok":true}'));
            try { Atlas_Jira.connectionTest(); System.assert(false); }
            catch (AuraHandledException expected) { System.assert(expected.getMessage().contains('not verified')); }
            Test.stopTest();
        }
    }
}
