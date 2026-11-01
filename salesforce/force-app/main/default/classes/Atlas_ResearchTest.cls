@IsTest
private class Atlas_ResearchTest {
    @TestSetup
    static void setup() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Person__c me = new Atlas_Person__c(Name = 'Me Myself', User__c = UserInfo.getUserId(), Active__c = true, Aliases__c = 'boss');
            insert me;
            insert new Atlas_Person__c(Name = 'Robin Report', Manager__c = me.Id, Active__c = true, Aliases__c = 'rob', Jira_Account_Id__c = 'jira-robin');
        }
    }

    static Map<String, Object> run(String requestJson) {
        return (Map<String, Object>) JSON.deserializeUntyped(Atlas_Research.run(requestJson));
    }

    static String failure(String requestJson) {
        try {
            Atlas_Research.run(requestJson);
        } catch (AuraHandledException e) {
            return e.getMessage();
        }
        System.assert(false, 'Expected a failure for ' + requestJson);
        return null;
    }

    @IsTest
    static void queriesFollowPagesUpToMaxRows() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Test.setMock(HttpCalloutMock.class, new Atlas_Mock());
            Test.startTest();
            Map<String, Object> onePage = run('{"op":"soql","query":"SELECT Name FROM Account","maxRows":2}');
            Map<String, Object> twoPages = run('{"op":"soql","query":"SELECT Name FROM Account","maxRows":400,"all":true}');
            Map<String, Object> tooling = run('{"op":"tooling","query":"SELECT Id FROM ApexClass","maxRows":5000}');
            Map<String, Object> search = run('{"op":"sosl","search":"FIND {Acme}"}');
            Test.stopTest();
            System.assertEquals(true, onePage.get('truncated'));
            System.assertEquals(1, ((List<Object>) onePage.get('pages')).size());
            System.assertEquals(false, twoPages.get('truncated'));
            System.assertEquals(2, ((List<Object>) twoPages.get('pages')).size());
            System.assertEquals(2000, tooling.get('maxRows'));
            System.assert(search.containsKey('searchRecords'));
        }
    }

    class NestedPages implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            String endpoint = request.getEndpoint();
            System.assert(!endpoint.endsWith('/children'), 'A child cursor must never become the parent page.');
            response.setBody(endpoint.endsWith('/parents')
                ? '{"totalSize":2,"done":true,"records":[{"Id":"second"}]}'
                : '{"nextRecordsUrl" : "/services/data/v67.0/query/parents", "totalSize":2,"done":false,"records":[{"Id":"first","Contacts":{"totalSize":4,"done":false,"records":[{"Id":"child"}],"nextRecordsUrl":"/services/data/v67.0/query/children"}}]}');
            return response;
        }
    }

    @IsTest
    static void shortPagesAndNestedCursorsStayIndependent() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Test.setMock(HttpCalloutMock.class, new NestedPages());
            Test.startTest();
            Map<String,Object> result = run('{"op":"soql","query":"SELECT Id, (SELECT Id FROM Contacts) FROM Account","maxRows":2}');
            Test.stopTest();
            List<Object> pages = (List<Object>)result.get('pages');
            System.assertEquals(2, pages.size(), 'Count actual rows, not the requested batch size.');
            System.assertEquals(false, result.get('truncated'));
            System.assert(JSON.serialize(pages[1]).contains('second'));
            System.assert(JSON.serialize(pages[0]).contains('/children'), 'Preserve child pagination in the raw result.');
        }
    }

    @IsTest
    static void describesObjects() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Map<String, Object> all = run('{"op":"describe"}');
            System.assert(((List<Object>) all.get('objects')).size() > 10);
            Map<String, Object> ticket = run('{"op":"describe","object":"' + Schema.SObjectType.Atlas_Ticket__c.getName() + '"}');
            System.assertEquals(true, ticket.get('custom'));
            System.assert(JSON.serialize(ticket.get('fields')).contains('Stage__c'));
            Map<String, Object> account = run('{"op":"describe","object":"Account"}');
            System.assert(((List<Object>) account.get('childRelationships')).size() > 0);
            for (Object row : (List<Object>) account.get('fields')) {
                Map<String, Object> field = (Map<String, Object>) row;
                if (field.get('name') == 'OwnerId') System.assertEquals(new List<Object>{ 'User' }, field.get('referenceTo'));
            }
            System.assert(failure('{"op":"describe","object":"NoSuchThing__c"}').contains('No object named'));

            // Naming fields returns only those, and says which names do not exist.
            Map<String, Object> some = run('{"op":"describe","object":"Account","fields":["Name","ownerid","Nope__c"]}');
            Set<Object> names = new Set<Object>();
            for (Object row : (List<Object>) some.get('fields')) names.add(((Map<String, Object>) row).get('name'));
            System.assertEquals(new Set<Object>{ 'Name', 'OwnerId' }, names);
            System.assertEquals(new List<Object>{ 'Nope__c' }, some.get('missing'));
            System.assertEquals(null, some.get('childRelationships'), 'A field lookup leaves out relationships and record types');
            System.assert(failure('{"op":"describe","object":"Account","fields":"Name"}').contains('must be a list'));

            // Long picklists show the first values and their total, unless the field is named.
            Integer longLists = 0;
            for (Schema.SObjectField field : Schema.SObjectType.Account.fields.getMap().values()) {
                Schema.DescribeFieldResult f = field.getDescribe();
                Integer active = 0;
                for (Schema.PicklistEntry value : f.getPicklistValues()) if (value.isActive()) active++;
                if (f.isAccessible() && active > 25) longLists++;
            }
            Integer capped = 0;
            for (Object row : (List<Object>) account.get('fields')) {
                Map<String, Object> field = (Map<String, Object>) row;
                if (field.get('picklistTotal') == null) continue;
                capped++;
                System.assertEquals(25, ((List<Object>) field.get('picklist')).size());
                Map<String, Object> one = run('{"op":"describe","object":"Account","fields":["' + field.get('name') + '"]}');
                List<Object> full = (List<Object>) ((Map<String, Object>) ((List<Object>) one.get('fields'))[0]).get('picklist');
                System.assertEquals(Integer.valueOf(String.valueOf(field.get('picklistTotal'))), full.size());
            }
            System.assertEquals(longLists, capped);
        }
    }

    @IsTest
    static void listsAndRetrievesMetadata() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Test.setMock(HttpCalloutMock.class, new Atlas_Mock());
            Test.startTest();
            Map<String, Object> types = run('{"op":"metadata-types"}');
            Map<String, Object> classes = run('{"op":"metadata-list","type":"ApexClass"}');
            Map<String, Object> reports = run('{"op":"metadata-list","type":"Report","folder":"Sales"}');
            Map<String, Object> retrieval = run('{"op":"retrieve","components":[{"type":"ApexClass","name":"Foo"}]}');
            Map<String, Object> status = (Map<String, Object>) JSON.deserializeUntyped(Atlas_Research.retrieveStatus((String) retrieval.get('asyncId')));
            Test.stopTest();
            System.assertEquals('ApexClass | folder classes', ((List<Object>) types.get('types'))[0]);
            System.assertEquals(2, classes.get('count'));
            System.assert(String.valueOf(classes.get('items')).contains('namespace pkg'));
            System.assertEquals('Report', reports.get('type'));
            System.assertEquals(true, status.get('done'));
            System.assertEquals(6, ((List<Object>) status.get('files')).size());
        }
    }

    @IsTest
    static void readsRestPathsOnly() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Test.setMock(HttpCalloutMock.class, new Atlas_Mock());
            Test.startTest();
            Map<String, Object> limits = run('{"op":"rest","path":"/services/data/v67.0/limits"}');
            Map<String, Object> shortPath = run('{"op":"rest","path":"limits"}');
            Test.stopTest();
            System.assert(((String) limits.get('body')).contains('DailyApiRequests'));
            System.assertEquals(Atlas_Api.DATA + '/limits', shortPath.get('path'));
            System.assert(failure('{"op":"rest","path":"/services/apexrest/x"}').contains('approved read-only Salesforce paths'));
            System.assert(failure('{"op":"rest","path":"/services/data/../x"}').contains('approved read-only Salesforce paths'));
        }
    }

    class RestResponse implements HttpCalloutMock {
        String expected;
        RestResponse(String expected) { this.expected = expected; }
        public HttpResponse respond(HttpRequest request) {
            System.assertEquals('GET', request.getMethod());
            if (expected != null) System.assertEquals(URL.getOrgDomainUrl().toExternalForm() + expected, request.getEndpoint());
            // Always succeed: a missing safety check must fail the test, not be
            // mistaken for a rejection because the mock/API rejected the path.
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            response.setBody('{}');
            return response;
        }
    }

    @IsTest
    static void restPreservesDocumentedReadsAndEncodedQueryValues() {
        System.runAs(Atlas_Mock.atlasUser()) {
            // Isolate fixture DML from the mocked callouts, as the other research
            // callout tests do. The reads themselves must not perform any DML.
            Test.startTest();
            for (String path : new List<String>{
                'limits', '/limits/', '/services/data/v67.0/limits', '/services/data/v66.0/limits',
                '/query/?q=SELECT+Id+FROM+Account', '/queryAll?q=SELECT%20Id%20FROM%20Account',
                '/query/01g000000000001AAA-2000', '/tooling/query/01g000000000001AAA-2000',
                '/tooling/query/?q=SELECT+Body+FROM+ApexClass', '/search/?q=FIND%20%7BAcme%7D',
                '/sobjects/', '/sobjects/Account/describe/', '/tooling/sobjects/', '/tooling/sobjects/ApexClass/describe',
                '/ui-api/record-ui/001000000000001?layoutTypes=Full&modes=View&optionalFields=Account.Name',
                '/ui-api/record-ui/001000000000001AAA,001000000000002AAA?formFactor=Small&childRelationships=Account.Contacts',
                '/query?q=SELECT+Id+FROM+Account+WHERE+Name%3D%27..%2F%252F%26_HttpMethod%3DDELETE%27'
            }) {
                String expected = path.startsWith('/services/data/') ? path : Atlas_Api.DATA + (path.startsWith('/') ? '' : '/') + path;
                Test.setMock(HttpCalloutMock.class, new RestResponse(expected));
                Integer calls = Limits.getCallouts();
                Map<String,Object> result = run(JSON.serialize(new Map<String,Object>{'op' => 'rest', 'path' => path}));
                System.assertEquals(expected, result.get('path'));
                System.assertEquals(calls + 1, Limits.getCallouts(), 'Allowed reads must actually reach the API.');
            }
            System.assertEquals(0, Limits.getDmlStatements(), 'REST research must not write records between reads.');
            Test.stopTest();
        }
    }

    @IsTest
    static void restRejectsWritesAndAmbiguousRoutesBeforeAnyCallout() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Test.setMock(HttpCalloutMock.class, new RestResponse(null));
            for (String path : new List<String>{
                '/tooling/executeAnonymous/?anonymousBody=insert+new+Account%28Name%3D%27Unsafe%27%29%3B',
                '/services/data/v67.0/tooling/executeAnonymous/?anonymousBody=System.debug%281%29%3B',
                '/tooling/runTestsSynchronous/?classnames=Example', '/tooling/runTestsAsynchronous',
                '/composite', '/actions/custom/apex/Example', '/sobjects/Account/001000000000001',
                '/services/apexrest/Example', 'https://example.com/limits', '//example.com/limits',
                '/limits/../tooling/executeAnonymous', '/limits/./', '/limits//',
                '/%74ooling/executeAnonymous', '/tooling%2FexecuteAnonymous', '/%2e%2e/tooling/executeAnonymous',
                '/limits/%252e%252e/tooling/executeAnonymous', '/services/data/v67.0%2ftooling/executeAnonymous',
                '/limits;anything', '/limits#fragment', '/limits\\tooling', '/limits\n',
                '/query?q=SELECT+Id+FROM+Account&_HttpMethod=DELETE',
                '/query?q=SELECT+Id+FROM+Account&%5fHttpMethod=POST',
                '/query?q=SELECT+Id+FROM+Account;_HttpMethod=POST',
                '/query?q=one&q=two', '/limits?anything=1',
                '/ui-api/record-ui/001000000000001?_HttpMethod=PATCH',
                '/ui-api/record-ui/001000000000001%2f..%2f..%2f..%2ftooling%2fexecuteAnonymous'
            }) {
                Integer calls = Limits.getCallouts();
                String message = failure(JSON.serialize(new Map<String,Object>{'op' => 'rest', 'path' => path}));
                System.assert(message.contains('approved read-only Salesforce paths'), 'Wrong rejection for ' + path + ': ' + message);
                System.assertEquals(calls, Limits.getCallouts(), 'No request may be sent for ' + path);
            }
        }
    }

    @IsTest
    static void reportsActivityForMeTeamAndNames() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Test.setMock(HttpCalloutMock.class, new Atlas_Mock());
            Test.startTest();
            Map<String, Object> mine = run('{"op":"activity","days":7}');
            Map<String, Object> team = run('{"op":"activity","who":"team","days":500}');
            Map<String, Object> named = run('{"op":"activity","who":"boss"}');
            Map<String, Object> listed = run('{"op":"activity","who":["' + UserInfo.getUserId() + '"]}');
            Test.stopTest();
            System.assertEquals(7, mine.get('days'));
            System.assertEquals(180, team.get('days'));
            System.assertEquals(4, Atlas_Mock.batches, 'Each activity request asks every Tooling source in one batch.');
            System.assertEquals(4, Atlas_Mock.calls, 'One callout per activity request, not one per source.');
            System.assert(JSON.serialize(mine.get('rows')).contains('Foo'));
            System.assert(JSON.serialize(mine.get('skipped')).contains('Flow'));
            System.assertEquals(1, ((List<Object>) named.get('people')).size());
            System.assertEquals(1, ((List<Object>) listed.get('people')).size());
        }
    }

    class LimitedActivity implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            String query = EncodingUtil.urlDecode(request.getEndpoint(), 'UTF-8');
            List<Object> records = new List<Object>();
            Integer count = query.contains(' FROM ApexClass ') ? 201 : query.contains(' FROM ApexTrigger ') ? 1 : 0;
            for (Integer i = 0; i < count; i++) records.add(new Map<String, Object>{
                'Id' => '01p000000000001AAA', 'Name' => 'Synthetic' + i, 'LastModifiedById' => UserInfo.getUserId(),
                'CreatedDate' => '2026-10-01T12:00:00.000Z', 'LastModifiedDate' => '2026-10-15T12:00:00.000Z'
            });
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            response.setBody(JSON.serialize(new Map<String, Object>{'records' => records, 'done' => count != 1,
                'nextRecordsUrl' => count == 1 ? '/services/data/v67.0/tooling/query/more' : null}));
            return response;
        }
    }

    @IsTest
    static void activityDisclosesLimitsAndShortPages() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Test.setMock(HttpCalloutMock.class, new LimitedActivity());
            Test.startTest();
            Map<String, Object> result = run('{"op":"activity"}');
            Test.stopTest();
            List<Object> limited = (List<Object>) result.get('limited');
            System.assertEquals(2, limited.size());
            System.assert(JSON.serialize(limited).contains('ApexClass: showing the latest 200'));
            System.assert(JSON.serialize(limited).contains('ApexTrigger: showing the latest 1'));
            System.assertEquals(201, ((List<Object>) result.get('rows')).size());
            System.assertEquals(0, ((List<Object>) result.get('skipped')).size());
        }
    }

    @IsTest
    static void activityAcceptsDecimalDaysAndFallsBackWhenTheBatchFails() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Test.setMock(HttpCalloutMock.class, new LimitedActivity());
            Test.startTest();
            Map<String, Object> result = run('{"op":"activity","days":30.0}');
            Test.stopTest();
            System.assertEquals(30, result.get('days'), 'A decimal number of days is used, not the 14-day default.');
            // LimitedActivity does not answer composite batches, so every source was asked on its own.
            System.assertEquals(201, ((List<Object>) result.get('rows')).size());
        }
    }

    @IsTest
    static void activityNeedsLinkedUsers() {
        System.runAs(Atlas_Mock.atlasUser()) {
            System.assert(failure('{"op":"activity","who":"reports"}').contains('No Salesforce users matched'));
            System.assert(failure('{"op":"activity","who":42}').contains('"who" must be'));
        }
    }

    @IsTest
    static void answersTicketsAndPeople() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Map<String, Object> tickets = run('{"op":"tickets","owner":"everyone"}');
            System.assertEquals(0, tickets.get('count'));
            Map<String, Object> directory = run('{"op":"people"}');
            System.assertEquals(2, ((List<Object>) directory.get('people')).size());
            System.assertEquals(null, directory.get('nextCursor'));
        }
    }

    @IsTest
    static void rejectsUnknownOrIncompleteRequests() {
        System.runAs(Atlas_Mock.atlasUser()) {
            System.assert(failure('{"op":"dance"}').contains('Unknown op "dance"'));
            System.assert(failure('{"op":"soql"}').contains('"query" is required'));
            Test.setMock(HttpCalloutMock.class, new Atlas_Mock());
            Test.startTest();
            System.assert(Atlas_Research.retrieveStatus('09S000000000001AAA').contains('"done":true'));
            Atlas_Mock.retrieveDone = false;
            System.assert(Atlas_Research.retrieveStatus('09S000000000001AAA').contains('"done":false'));
            Test.stopTest();
        }
    }
}
