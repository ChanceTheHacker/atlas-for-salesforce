// Tests the Atlas LWC library (salesforce/force-app/main/default/lwc/atlasLib).
// LWC files import each other without extensions, so the library is bundled
// with esbuild before Node loads it.
import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { build } from "esbuild";

const entry = new URL("../salesforce/force-app/main/default/lwc/atlasLib/atlasLib.js", import.meta.url).pathname;
const dir = await mkdtemp(join(tmpdir(), "atlas-lib-"));
await build({ entryPoints: [entry], bundle: true, platform: "node", format: "esm", outfile: join(dir, "lib.mjs"), logLevel: "warning" });
const L = await import(join(dir, "lib.mjs"));
await rm(dir, { recursive: true });

const people=[{id:"P1",name:"Chance",jiraId:"acc-me",aliases:["me","chance"],isMe:true},{id:"P2",name:"Robert Smith",jiraId:"acc-rob",aliases:["rob","bobby"],isMyReport:true},{id:"P3",name:"Old",jiraId:"acc-old",aliases:[],active:false}];

test("persistent intake rejects agent-supplied answers and conflicting identities", () => {
  assert.throws(() => L.intakeQuestions({questions:[{id:'Q1',question:'Why?',answer:'guessed'}]}), /answers/i);
  assert.throws(() => L.intakeQuestions({questions:[{id:'Q1',question:'Why?'},{id:'Q1',question:'Who?'}]}), /unique/i);
  const questions = L.intakeQuestions({questions:[{id:'Q1',question:'Why?'}]}, [{id:'Q1',question:'Why?',answer:'Confirmed'}]);
  assert.equal(questions[0].answer, 'Confirmed');
  assert.equal(L.intakeQuestions({questions:[{id:'Q1',question:'Changed?'}]}, questions)[0].answer, '');
  assert.throws(() => L.intakeAliases({aliases:[{alias:'Sam',reason:'Assign',userId:'guess'}]}, people), /cannot supply/i);
  assert.equal(L.intakeAliases({aliases:[{alias:'Bobby',reason:'Assign'}]},people)[0].personId, 'P2');
});

test("diff", () => {
  const rnd = (n) => Array.from({length:n},(_,i)=>"line "+(i*7%13)+" "+(i%5)).join("\n");
  for (const [a,b] of [["",""],["a","a"],["a\nb\nc","a\nx\nc"],["a\nb","a\nb\nc"],["x\ny","" ],[rnd(200), rnd(210).replace(/line 3/g,"LINE")]]) {
    if (a===b) continue; const {rows} = L.lineDiff(a,b,1000000);
    const rebuiltOld = rows.filter(r=>r.type!=="add").map(r=>r.text).join("\n");
    const rebuiltNew = rows.filter(r=>r.type!=="del").map(r=>r.text).join("\n");
    assert.equal(rebuiltOld, a.split("\n").join("\n")); assert.equal(rebuiltNew, b);
  }
  const d = L.lineDiff("1\n2\n3\n4\n5\n6\n7\n8\n9\n10","1\n2\n3\n4\n5\nX\n7\n8\n9\n10");
  assert.equal(d.added,1); assert.equal(d.removed,1);
  assert.deepEqual(d.rows.map(r=>r.type),["gap","same","same","same","del","add","same","same","same","gap"]);
  assert.equal(d.rows[0].text,"… 2 unchanged lines …");
  const big = L.lineDiff(Array.from({length:5000},(_,i)=>"a"+i).join("\n"), Array.from({length:5000},(_,i)=>"b"+i).join("\n"));
  assert.equal(big.added,5000); assert.equal(big.removed,5000);
});

test("dates", () => {
  assert.equal(L.parseJiraDate("14/Oct/26"),"2026-10-14");
  assert.equal(L.parseJiraDate("2026-10-14T10:00:00.000-0400"),"2026-10-14");
  assert.equal(L.parseJiraDate("31/Feb/26"),"");
  assert.ok(L.parseJiraDateTime("14/Oct/26 1:05 PM").length>10);
  assert.equal(L.formatDate("2026-10-04","dd/MMM/yy h:mm a"),"04/Oct/26 12:00 AM");
  assert.equal(L.formatDate("2026-10-04","yyyy-MM-dd"),"2026-10-04");
  assert.equal(L.formatDate("2026-10-04","d 'of' MMMM yyyy"),"4 of October 2026");
});

test("csv", () => {
  const p = L.parseCSV('﻿Issue key,Summary,Status\nABC-1,"Hello, ""x""",Done\r\nABC-2,Line\n');
  assert.deepEqual(p.rows[0],["ABC-1",'Hello, "x"',"Done"]);
  assert.throws(()=>L.parseCSV('a,b\n"x'),/never closes/);
});

test("mapping", () => {
  const cfg = JSON.stringify({"config.field.mappings":{"Title":{"jira.field":"summary"},"Kind":{"jira.field":"issuetype"},"Due":{"jira.field":"duedate"},"Epic Link":{"existing.custom.field":"10014"},"Epic Name":{"existing.custom.field":"10011"},"Owner":{"jira.field":"assignee"},"Sprint":{"existing.custom.field":"10020"}},"config.value.mappings":{"Kind":{"Work":"Task"}},"config.delimiter":";","config.date.format":"dd/MMM/yy","config.project":{"project.key":"ABC"}});
  const m = L.parseMapping(cfg);
  assert.equal(m.headers.summary,"Title"); assert.equal(m.headers.epicLink,"Epic Link"); assert.equal(m.delimiter,";"); assert.deepEqual(m.unmapped,["Sprint"]);
  const lineMap = L.parseMapping("Due Date = Due date\nAssignee -> Assignee Id\n");
  assert.equal(lineMap.headers.dueDate,"Due date"); assert.equal(lineMap.headers.assignee,"Assignee Id");
  assert.throws(()=>L.parseMapping("hello"),/No mappings/);
  const tix=[{id:"E",atlasId:"TKT-1",issueType:"Epic",jiraKey:"ABC-10",summary:"Epic one",epicName:"E1",dueDate:"2026-11-01",assigneeId:"P2"},{id:"T",atlasId:"TKT-2",issueType:"Task",summary:"Task",epicId:"E",epicAtlasId:"TKT-1",dueDate:"2026-11-02"}];
  const out = L.exportCSV(tix,{people,mapping:m,me:people[0]});
  assert.equal(out.headers.join("|"),"Title|Kind|Description|Priority|Due|Epic Name|Epic Link|Owner");
  assert.deepEqual(out.rows[1],["Task","Work","","","02/Nov/26","","ABC-10",""]);
  assert.ok(out.csv.includes('"Title";"Kind"'));
});

test("value mappings write the CSV value that Jira turns into the ticket's value", () => {
  const mapping = L.parseMapping(JSON.stringify({"config.field.mappings":{"Priority":{"jira.field":"priority"}},
    "config.value.mappings":{"Priority":{"High":"Highest","Medium":"High"}}}));
  const row = (priority) => {
    const out = L.exportCSV([{id:"T",summary:"Work",issueType:"Task",priority,dueDate:"2026-11-02"}], {people,mapping,me:people[0]});
    return out.rows[0][out.headers.indexOf("Priority")];
  };
  assert.equal(row("High"), "Medium", "High is a source key, but Medium is the CSV value that Jira imports as High.");
  assert.equal(row("Highest"), "High");
  assert.equal(row("Low"), "Low", "Unmapped values pass through.");
  const lossy = L.parseMapping(JSON.stringify({"config.field.mappings":{"Priority":{"jira.field":"priority"}},
    "config.value.mappings":{"Priority":{"High":"Highest"}}}));
  assert.throws(() => L.exportCSV([{id:"T",summary:"Work",issueType:"Task",priority:"High",dueDate:"2026-11-02"}], {people,mapping:lossy,me:people[0]}),
    /would import into Jira as "Highest"/);
});

test("custom fields survive draft checks, mappings and CSV without changing unassigned", () => {
  const result = L.checkTicketBatch({tickets:[{ref:"T1",summary:"Explicit unassigned",assignee:null,customFields:{Team:" A "}}], updates:[{target:"ABC-1", changes:{customFields:{Team:"B"}}}]}, {people});
  assert.deepEqual(result.errors, []);
  assert.equal(result.batch.tickets[0].assigneeId, null);
  assert.equal(result.batch.tickets[0].customFields.Team, " A ");
  const mapping = L.parseMapping("Team = Squad");
  const out = L.exportCSV([{...result.batch.tickets[0], planning:{customFields:{Team:" A "}}}], {people,mapping,me:people[0]});
  assert.equal(out.rows[0][out.headers.indexOf("Assignee")], "");
  assert.equal(out.rows[0][out.headers.indexOf("Squad")], " A ");
  const imported = L.importRows(L.parseCSV('Issue key,Summary,Squad,Label,Label\nABC-1,Work, A ,one,two\n'), {mapping}).rows[0];
  assert.deepEqual(imported.customFields, {Team:" A "});
  assert.equal(imported.raw.values.at(-1), "two");
  assert.throws(() => L.exportCSV([{summary:"Missing ID",assigneeId:"missing"}], {people}), /confirmed Jira/);
  assert.ok(L.checkTicketBatch({tickets:[{ref:"T",summary:"Invalid",customFields:{Team:123}}]}, {people}).errors.length);
});

test("ticket replies expose continuation and backup replies do not invent local saves", () => {
  const text=L.resultText({id:"tickets",op:"tickets"},{count:1,hasMore:true,nextCursor:"cursor-1",scope:"Non-atomic",tickets:[{atlasId:"TKT-1",planning:{customFields:{Team:" A "}}}]});
  assert.match(text,/"cursor":"cursor-1"/); assert.match(text,/more remain/); assert.match(text,/ A /);
  const reply=L.backupReply({name:"CHG-1",found:[],missing:[]},[],true);
  assert.match(reply,/does not confirm/); assert.doesNotMatch(reply,/was downloaded/);
  assert.throws(()=>L.parseMapping("Team = Squad\nOther = Squad"),/same CSV header/);
  assert.throws(()=>L.importRows(L.parseCSV('Issue key,Summary,Team,Squad\nDEMO-1,T,A,B'),{mapping:{customHeaders:{Team:"Squad"}}}),/Multiple CSV columns/);
});

test("backup replies name bundles the retrieve could not match, one line each", () => {
  const change = {name: "CHG-2", found: [{type: "LightningComponentBundle", name: "atlasWork"}], missing: [],
    blocked: ["LightningComponentBundle atlasLib (Salesforce reported files in lwc/atlasLib that do not all belong to it)"]};
  const reply = L.backupReply(change, [], false);
  assert.match(reply, /Backed up:\n- LightningComponentBundle atlasWork/);
  assert.match(reply, /NOT backed up[^\n]*Do not propose changes to these:\n- LightningComponentBundle atlasLib \(Salesforce reported/);
  assert.doesNotMatch(L.backupReply({...change, blocked: []}, [], false), /NOT backed up/);
});

test("files the agent already has become a one-line note until they change or it asks again", () => {
  const sent = {}, file = (text) => ({path: "classes/Foo.cls", text});
  const first = L.resultText({id: "r", op: "retrieve"}, {files: [file("class Foo {}"), {path: "package.xml", text: "<x/>"}]}, null, sent);
  assert.match(first, /--- FILE classes\/Foo\.cls ---\nclass Foo \{\}\n--- END FILE/); assert.deepEqual(Object.keys(sent), ["classes/Foo.cls"]);
  const backup = L.backupReply({name: "CHG-1", found: [], missing: []}, [file("class Foo {}")], true, sent);
  assert.match(backup, /--- FILE classes\/Foo\.cls \(unchanged: same text as sent at \d\d:\d\d; add "resend":true if you no longer have it\) ---/);
  assert.doesNotMatch(backup, /class Foo \{\}/);
  assert.match(L.resultText({id: "r", op: "retrieve", resend: true}, {files: [file("class Foo {}")]}, null, sent), /class Foo \{\}/);
  assert.match(L.backupReply({name: "CHG-1", found: [], missing: []}, [file("class Foo { }")], true, sent), /class Foo \{ \}/, "Any change sends the text again");
  assert.match(L.filesText([file("class Foo {}")]), /class Foo \{\}/, "Without a memory every file is sent");
  const many = {};
  L.filesText(Array.from({length: 305}, (_, i) => ({path: `f${i}`, text: String(i)})), many);
  assert.equal(Object.keys(many).length, 300); assert.ok(!("f0" in many) && "f304" in many);
});

test("people replies render paged directories, manager IDs and explicit continuation", () => {
  const text = L.resultText({ id: "directory", op: "people" }, { people: [{ ...people[1], managerId: "P1" }], nextCursor: "P2" });
  assert.match(text, /Atlas person P2.*manager P1/);
  assert.match(text, /"afterId":"P2"/);
  assert.match(text, /nextCursor: "P2"/);
  assert.match(L.resultText({ id: "last", op: "people" }, { people: [], nextCursor: null }), /Final page/);
  assert.match(L.resultText({ id: "old", op: "people" }, people), /Robert Smith/);
});

test("import", () => {
  const imp = L.importRows(L.parseCSV("Issue key,Summary,Status,Assignee,Due date,Custom field (Epic Link),Updated\nABC-1,S,In Review,bobby,14/Oct/26,ABC-9,14/Oct/26 9:00 AM\nnotakey,x,,,,,\n"),{people});
  assert.equal(imp.rows[0].assigneeJiraId,"acc-rob"); assert.equal(imp.rows[0].statusCategory,"In Progress"); assert.equal(imp.rows[0].dueDate,"2026-10-14"); assert.equal(imp.rows[0].epicKey,"ABC-9"); assert.equal(imp.skipped.length,1);
});

test("Jira imports preserve descriptions and distinguish invalid dates from clearing a date", () => {
  const csv = 'Issue key,Summary,Description,Due date,Custom field (Epic Link)\nABC-1,S,Context,not-a-date,\n';
  const imported = L.importRows(L.parseCSV(csv));
  assert.equal(imported.rows[0].description, "Context");
  assert.equal(Object.hasOwn(imported.rows[0], "dueDate"), false);
  assert.equal(imported.rows[0].epicKey, "");
  assert.ok(imported.skipped.some((s) => /date/i.test(s)));
  const clear = L.importRows(L.parseCSV('Issue key,Summary,Due date\nABC-1,S,\n'));
  assert.equal(clear.rows[0].dueDate, "");
});

test("tickets", () => {
  const chk = L.checkTicketBatch({type:"atlas-tickets",epics:[{ref:"E1",summary:"E"}],tickets:[{ref:"T1",epicRef:"E1",summary:"t",assignee:"Bobby"},{ref:"T2",summary:"t2"},{ref:"T3",summary:"t3",assignee:"zed",dueDate:"2026-02-30"}],updates:[{target:"abc-1",changes:{assignee:"rob",statusCategory:"Done"},comments:"done"}]},{people});
  assert.equal(chk.batch.tickets[0].assigneeId,"P2"); assert.equal(chk.batch.tickets[1].assigneeId,"P1"); assert.equal(chk.batch.epics[0].epicName,"E");
  assert.equal(chk.errors.length,2, chk.errors.join("\n")); assert.match(chk.errors[0],/"zed" is not a unique, verified identity in PEOPLE/);
  assert.equal(chk.batch.updates[0].changes.assigneeId,"P2"); assert.deepEqual(chk.batch.updates[0].comments,["done"]); assert.equal(chk.batch.updates[0].target,"ABC-1");
  assert.equal(L.findPerson(people,"acc-old"),null);
});

test("requests + replies", () => {
  assert.equal(L.checkRequests({type:"atlas-request",requests:[{op:"soql",query:"x"},{op:"nope"}]}).errors.length,1);
  const r = L.resultText({id:"q1",op:"soql"},{maxRows:1,truncated:false,pages:[{totalSize:2,records:[{attributes:{type:"Account"},Id:"1",Owner:{attributes:{},Name:"A"},Contacts:{totalSize:1,done:true,records:[{attributes:{},Id:"c"}]}},{Id:"2"}]}]});
  assert.ok(r.includes('Columns: ["Id","Owner.Name","Contacts"]\n["1","A",[{"Id":"c"}]]') && r.includes("1 of 2 rows"), r);
  const rows = L.resultText({id:"q3",op:"soql"},{maxRows:5,pages:[{totalSize:3,records:[
    {attributes:{type:"Account"},Id:"1",Name:"Acme",Owner:null},{attributes:{type:"Account"},Id:"2",Name:"Bolt",Owner:{attributes:{type:"User"},Name:"Ann",Manager:{attributes:{type:"User"},Name:"Bo"}}},
    {attributes:{type:"Account"},Id:"3",Name:"Says \"hi\" | there\nnext",BillingAddress:{city:"Paris"}}]}]});
  assert.equal(rows.split("\n").slice(2).join("\n"), [
    'Columns: ["Id","Name","Owner.Name","Owner.Manager.Name","BillingAddress"]',
    '["1","Acme",null,null,null]', '["2","Bolt","Ann","Bo",null]', '["3","Says \\"hi\\" | there\\nnext",null,null,{"city":"Paris"}]'].join("\n"), "Each row stays one unambiguous line");
  assert.equal((rows.match(/"Name"/g) || []).length, 1, "Field names appear once, in the header");
  const sosl = L.resultText({id:"s",op:"sosl"},{searchRecords:[{attributes:{type:"Account"},Id:"1",Name:"A"},{attributes:{type:"Contact"},Id:"2",LastName:"B"},{attributes:{type:"Account"},Id:"3",Name:"C"}]});
  assert.match(sosl, /3 match\(es\)\nAccount \(2\)\nColumns: \["Id","Name"\]\n\["1","A"\]\n\["3","C"\]\nContact \(1\)\nColumns: \["Id","LastName"\]\n\["2","B"\]/);
  assert.ok(L.requestReply([r]).endsWith(L.LIMIT_REMINDER));
  const d = L.resultText({id:"q2",op:"describe"},{object:"Account",label:"Account",keyPrefix:"001",fields:[
    {name:"OwnerId",label:"Owner",type:"REFERENCE",referenceTo:["User"],relationshipName:"Owner",required:true},
    {name:"Rating",label:"Rating",type:"PICKLIST",picklist:["Hot","Cold"],help:"How warm"},
    {name:"State",label:"State",type:"PICKLIST",picklist:["AK","AL"],picklistTotal:52}],childRelationships:[],recordTypes:[],missing:["Nope__c"]});
  assert.ok(d.includes("OwnerId | Owner | REFERENCE | → User via Owner | required") && d.includes("values: Hot, Cold | help: How warm"), d);
  assert.ok(d.includes('values: AK, AL (+50 more; describe with "fields":["State"] for all)') && d.includes("No such field: Nope__c"), d);
});

test("Support Tickets mode has a safe prompt and preserves the report route in reminders", () => {
  const boot={user:{id:"005",name:"Chance"},org:{name:"Demo",id:"00D",isSandbox:false,edition:"Developer Edition",namespace:"demo"},people};
  const context={conversation:{id:"conversation-1",mode:"support-tickets",title:"Support ticket",request:"Investigate the production error"},boot,mine:{replyLimit:100000},jira:{}};
  const prompt=L.firstPrompt(context), reminder=L.rulesReminder(context);
  assert.equal(L.MODE_LABELS["support-tickets"], "Support Tickets");
  assert.match(prompt,/ATLAS: SUPPORT TICKETS/);
  assert.match(prompt,/Developer Edition/);
  assert.match(prompt,/non-sandbox org/);
  assert.doesNotMatch(prompt,/\(production org,/);
  assert.match(prompt,/atlas-support-ticket-report/);
  assert.match(prompt,/Never send atlas-backup, atlas-change, atlas-assign/);
  assert.doesNotMatch(prompt,/CHANGE SALESFORCE: back up/);
  assert.doesNotMatch(prompt,/FILES: atlas-files/);
  assert.match(reminder,/SUPPORT TICKETS REQUEST ID: conversation-1/);
  assert.match(reminder,/connected org's queried evidence must remain separate/);
});

test("Support Tickets prompts teach only supported clarification routes and request production facts from the administrator", () => {
  const context={conversation:{id:"conversation-1",mode:"support-tickets",title:"Support ticket",request:"Investigate the production error"},boot:{user:{name:"Chance"},org:{},people:[]},mine:{replyLimit:100000},jira:{}};
  for (const prompt of [L.firstPrompt(context),L.rulesReminder(context)]) {
    assert.match(prompt,/atlas-questions/);
    assert.match(prompt,/Ask the administrator directly for missing production facts/);
    assert.doesNotMatch(prompt,/atlas-users|atlas-context|atlas-jira-refresh/);
    assert.doesNotMatch(prompt,/op":"users"|op":"tickets"/);
    assert.doesNotMatch(prompt,/add "resend":true to the request \(or to atlas-backup\)/);
    assert.doesNotMatch(prompt,/Ask me only for business decisions the org cannot answer/);
  }
});

test("REST guidance lists only the read-only routes and parameters the server accepts", () => {
  for (const makePrompt of [L.firstPrompt,L.rulesReminder]) {
    const prompt=makePrompt({conversation:{id:"conversation-1",mode:"support-tickets",title:"Support ticket"},boot:{org:{},people:[]},mine:{},jira:{}});
    assert.doesNotMatch(prompt,/any GET under \/services\/data/);
    assert.match(prompt,/query, \/queryAll/);
    assert.match(prompt,/\/tooling\/query/);
    assert.match(prompt,/ui-api\/record-ui/);
    assert.match(prompt,/Only q is allowed on query\/search URLs/);
    assert.match(prompt,/layoutTypes, modes, optionalFields, childRelationships and formFactor/);
  }
});

const ticketReport = (extra={}) => ({
  type:"atlas-support-ticket-report", requestId:"conversation-1", organization:"Production Salesforce org, name reported by admin",
  productionFacts:["Administrator reports Save fails on a Case."], qaEvidence:["Connected org has an active Case flow."],
  hypotheses:["The production flow may differ; not verified."], likelyProblem:"A flow may reject the reported update.", confidence:"Moderate",
  missingEvidence:["Production flow version and failed record."], recommendedSolution:"Have an administrator compare the production flow before changing it.",
  productionSteps:["Confirm the production org and affected record.","Compare the active flow version before making a change."],
  prerequisites:["A production backup."], permissions:["A Salesforce administrator."], verification:["Repeat the same update with a test record."],
  stopConditions:["Stop if the production flow differs from the connected org."], rollback:["Restore the previous flow version if the approved change causes failures."], jiraEscalation:null,
  ...extra,
});

test("Support Tickets report validation separates evidence and formats readable numbered instructions", () => {
  const checked=L.checkSupportTicketReport(ticketReport(),"conversation-1");
  assert.equal(checked.confidence,"Moderate");
  const text=L.formatSupportTicketReport(checked,{name:"Demo",id:"00D",isSandbox:true,edition:"Developer Edition",namespace:"demo"});
  assert.match(text,/Facts reported about production by the administrator/);
  assert.match(text,/Evidence observed in the connected Salesforce org/);
  assert.match(text,/Hypotheses and differences that have not been verified/);
  assert.match(text,/1\. Confirm the production org and affected record\.\n2\. Compare the active flow/);
  assert.match(text,/demo/);
  assert.throws(()=>L.checkSupportTicketReport(ticketReport({requestId:"wrong"}),"conversation-1"),/exact requestId/);
  assert.throws(()=>L.checkSupportTicketReport(ticketReport({productionFacts:[],qaEvidence:[]}),"conversation-1"),/at least one/);
  assert.throws(()=>L.checkSupportTicketReport(ticketReport({productionSteps:[]}),"conversation-1"),/productionSteps/);
  assert.throws(()=>L.checkSupportTicketReport(ticketReport({unknown:"write"}),"conversation-1"),/unsupported fields/);
  assert.throws(()=>L.checkSupportTicketReport(ticketReport({confidence:"Certain"}),"conversation-1"),/confidence/);
});

const managerPeople = people.map((person) => person.id === "P2" ? {...person,active:true} : person);
const managerJira = {projectKey:"ABC",externalCredential:"Configured",writeEnabled:true,apiVersion:"3",reviewManagerPersonId:"P2",reviewManagerIdentityType:"accountId"};

test("Support Tickets local Bug drafts require the configured manager and send a minimal no-date batch", () => {
  const message={type:"atlas-tickets",requestId:"conversation-1",tickets:[{ref:"ATLBUG",issueType:"Bug",summary:"Save fails",description:"The admin reports an error; connected-org evidence is separate.",assignee:"acc-rob"}]};
  const checked=L.checkSupportTicketBugDraft(message,"conversation-1",{people:managerPeople,projectKey:"ABC",jira:managerJira});
  assert.deepEqual(checked.errors,[]);
  assert.deepEqual(checked.batch,{projectKey:"ABC",epics:[],tickets:[{ref:"ATLBUG",issueType:"Bug",summary:"Save fails",description:"The admin reports an error; connected-org evidence is separate.",priority:"",dueDate:null,assigneeId:"P2"}],updates:[]});
  assert.throws(()=>L.checkSupportTicketBugDraft({...message,projectKey:"OTHER"},"conversation-1",{people:managerPeople,projectKey:"ABC",jira:managerJira}),/project key or unsupported/);
  const updates=L.checkSupportTicketBugDraft({...message,updates:[{target:"ABC-1",changes:{status:"Done"}}]},"conversation-1",{people:managerPeople,projectKey:"ABC",jira:managerJira});
  assert.match(updates.errors.join(" "),/cannot update existing/);
  const task=L.checkSupportTicketBugDraft({...message,tickets:[{...message.tickets[0],issueType:"Task"}]},"conversation-1",{people:managerPeople,projectKey:"ABC",jira:managerJira});
  assert.match(task.errors.join(" "),/only allowed issueType/);
  const unassigned=L.checkSupportTicketBugDraft({...message,tickets:[{...message.tickets[0],assignee:null}]},"conversation-1",{people,projectKey:"ABC",jira:{projectKey:"ABC"}});
  assert.deepEqual(unassigned.errors,[]);
  assert.equal(unassigned.batch.tickets[0].assigneeId,null);
  assert.equal(unassigned.batch.tickets[0].dueDate,null);
  const wrongManager=L.checkSupportTicketBugDraft(message,"conversation-1",{people:managerPeople,projectKey:"ABC",jira:{projectKey:"ABC"}});
  assert.match(wrongManager.errors.join(" "),/Set assignee to null/);
});

test("Support Tickets live Jira accepts only a manager-assigned Bug with the review label", () => {
  const proposal={type:"atlas-jira-write",requestId:"conversation-1",operationId:"bug_1",operation:"create",fields:{project:{key:"ABC"},issuetype:{name:"Bug"},summary:"Save fails",description:"Evidence and what remains unverified.",assignee:{accountId:"acc-rob"},labels:["atlas-manager-review"]}};
  const request=L.checkSupportTicketJiraWrite(proposal,"conversation-1",{people:managerPeople,jira:managerJira});
  assert.equal(request.operation,"create");
  assert.throws(()=>L.checkSupportTicketJiraWrite({...proposal,operation:"update",issueKey:"ABC-1"},"conversation-1",{people:managerPeople,jira:managerJira}),/only propose a new Jira Bug/);
  assert.throws(()=>L.checkSupportTicketJiraWrite({...proposal,fields:{...proposal.fields,assignee:{accountId:"acc-me"}}},"conversation-1",{people:managerPeople,jira:managerJira}),/configured review manager/);
  assert.throws(()=>L.checkSupportTicketJiraWrite({...proposal,fields:{...proposal.fields,labels:["other"]}},"conversation-1",{people:managerPeople,jira:managerJira}),/atlas-manager-review/);
  assert.throws(()=>L.checkSupportTicketJiraWrite(proposal,"conversation-1",{people:managerPeople,jira:{...managerJira,writeEnabled:false}}),/not available/);
  const dated={...proposal,fields:{...proposal.fields,priority:{name:"High"},duedate:"2026-12-01"}};
  const datedRequest=L.checkSupportTicketJiraWrite(dated,"conversation-1",{people:managerPeople,jira:managerJira});
  assert.deepEqual(datedRequest.fields.priority,{name:"High"});
  assert.equal(datedRequest.fields.duedate,"2026-12-01");
  assert.equal(Object.hasOwn(request.fields,"priority"),false,"do not invent a default priority");
  assert.equal(Object.hasOwn(request.fields,"duedate"),false,"do not invent a due date");
  assert.throws(()=>L.checkSupportTicketJiraWrite({...proposal,fields:{...proposal.fields,priority:{name:""}}},"conversation-1",{people:managerPeople,jira:managerJira}),/priority/);
  assert.throws(()=>L.checkSupportTicketJiraWrite({...proposal,fields:{...proposal.fields,priority:{name:"High",id:"1"}}},"conversation-1",{people:managerPeople,jira:managerJira}),/priority/);
  assert.throws(()=>L.checkSupportTicketJiraWrite({...proposal,fields:{...proposal.fields,duedate:"2026-02-30"}},"conversation-1",{people:managerPeople,jira:managerJira}),/duedate/);
  assert.equal(L.supportTicketBugOperationId("conversation-1","Save fails","Details"),L.supportTicketBugOperationId("conversation-1","Save fails","Details"));
  assert.notEqual(L.supportTicketBugOperationId("conversation-1","Save fails","Details"),L.supportTicketBugOperationId("conversation-1","Save fails","Changed"));
  const rob = {projectKey:"ABC",identityType:"accountId",jiraId:"acc-rob"};
  const kim = {...rob,jiraId:"acc-kim"};
  assert.equal(L.supportTicketBugOperationId("conversation-1","Save fails","Details",rob),L.supportTicketBugOperationId("conversation-1","Save fails","Details",rob));
  assert.notEqual(L.supportTicketBugOperationId("conversation-1","Save fails","Details",rob),L.supportTicketBugOperationId("conversation-1","Save fails","Details",kim),"a different manager is a different reviewed payload");
});

test("all modes teach all supported exchanges without inventing admin permissions", () => {
  for (const mode of ["Source", "Task", "Files"]) {
    const prompt = L.firstPrompt({conversation:{mode,title:"Inspect the layout"},boot:{user:{name:"Teammate"},org:{},people:[]},mine:{},jira:{}});
    assert.ok(prompt.includes('"epicRef"') && prompt.includes('"edits"') && prompt.includes('"artifacts"'), mode);
    assert.doesNotMatch(prompt, /a full administrator/);
  }
});

test("non-ticket first prompts and reminders retain research and exactly one intake protocol", () => {
  for (const mode of ["Source", "Task", "Files"]) {
    const context={conversation:{mode,title:"Inspect the layout"},boot:{user:{name:"Teammate"},org:{},people:[]},mine:{},jira:{}};
    for (const makePrompt of [L.firstPrompt,L.rulesReminder]) {
      const prompt=makePrompt(context);
      assert.match(prompt,/READ THE ORG: atlas-request/);
      assert.equal((prompt.match(/CLARIFICATIONS AND IDENTITIES/g) || []).length,1);
    }
  }
});

test("initial prompts and rules reminders teach copy-safe JSON without changing source text", () => {
  for (const mode of ["Source", "Task", "Files"]) {
    const context = {conversation:{mode,title:"Fix the component"},boot:{org:{},people:[]},mine:{},jira:{}};
    for (const makePrompt of [L.firstPrompt, L.rulesReminder]) {
      const prompt = makePrompt(context);
      assert.match(prompt, /one complete JSON object inside a fenced code block labeled json/);
      assert.match(prompt, /Keep explanations outside the block/);
      assert.match(prompt, /Copy button/);
      assert.match(prompt, /JSON\.stringify[\s\S]*JSON\.parse/);
      assert.match(prompt, /double quotes, backslashes, line breaks and tabs/);
      assert.match(prompt, /after JSON decoding[\s\S]*character for character/);
      assert.match(prompt, /Do not remove apostrophes/);
      assert.match(prompt, /Splitting does not fix invalid JSON/);
      assert.match(prompt, /Serialize and validate each part envelope too/);
      assert.match(prompt, /14,000 characters[\s\S]*JSON escaping, code fences and prose/);
    }
  }
});

test("Files and UAT prompts distinguish document capacity from the per-response ceiling", () => {
  for (const mode of ["Files", "uat"]) {
    const context = {conversation:{id:"conversation-1",mode,title:"Long plan",request:"Cover every branch",uat:{componentType:"Flow",apiName:"Account_Onboarding",goal:"Verify safe onboarding",testing:""}},boot:{org:{},people:[]},mine:{replyLimit:1000000},jira:{}};
    for (const makePrompt of [L.firstPrompt, L.rulesReminder]) {
      const prompt = makePrompt(context);
      assert.match(prompt, /HARD RESPONSE LIMIT: 14,000 characters/);
      assert.match(prompt, /Aim for at most 12,000 characters/);
      assert.match(prompt, /not tokens, words, or the document's final size/);
      assert.match(prompt, /Count the exact final response/);
      assert.match(prompt, /ONE envelope per response/);
      assert.match(prompt, /wait for me to say Continue/);
      assert.match(prompt, /Never truncate, summarize away, or omit tests/);
      const contract = prompt.slice(prompt.indexOf(mode === "uat" ? "WORD PLAN CONTRACT" : "FILES: atlas-files"));
      assert.match(contract, /document limits, not permission to exceed 14,000 characters/);
      assert.match(contract, /reassembled JSON object/);
      assert.ok(prompt.endsWith(L.LIMIT_REMINDER));
    }
  }
});

test("source-edit prompts require current source text instead of reconstructed find values", () => {
  for (const mode of ["Source", "Task", "Files"]) {
    const context = {conversation:{mode,title:"Fix the component"},boot:{org:{},people:[]},mine:{},jira:{}};
    for (const makePrompt of [L.firstPrompt, L.rulesReminder]) {
      const prompt = makePrompt(context);
      assert.match(prompt, /Never type or reconstruct a "find" value from memory/);
      assert.match(prompt, /exact text in the most recent atlas-backup or retrieve response for that file in this conversation/);
      assert.match(prompt, /request it again \(retrieve or atlas-backup with "resend":true\) and wait for the returned text before writing the edit/);
      assert.match(prompt, /Do not approximate it or use a summary, earlier proposal or remembered version as source text/);
    }
  }
});

test("follow-up reminders put the hard response ceiling and continuation rule first", () => {
  assert.match(L.LIMIT_REMINDER, /^REPLY LIMIT: 14,000 characters/);
  assert.match(L.LIMIT_REMINDER, /Files and UAT/);
  assert.match(L.LIMIT_REMINDER, /12,000/);
  assert.match(L.LIMIT_REMINDER, /Count final text/);
  assert.match(L.LIMIT_REMINDER, /ONE per response/);
  assert.match(L.LIMIT_REMINDER, /STOP; wait for Continue/);
  assert.match(L.LIMIT_REMINDER, /Never truncate/);
});

test("follow-up reminders retain copy-safe JSON rules without crowding out reply parts", () => {
  assert.match(L.LIMIT_REMINDER, /fenced json code block/);
  assert.match(L.LIMIT_REMINDER, /Serialize and validate/);
  assert.match(L.LIMIT_REMINDER, /preserve exact find text/);
  assert.match(L.LIMIT_REMINDER, /14,000 characters/);
  assert.match(L.LIMIT_REMINDER, /separately serialized atlas-response-part/);
  assert.match(L.LIMIT_REMINDER, /For source edits, preserve exact find text: copy from the latest backup\/retrieve, never from memory/);
  assert.match(L.LIMIT_REMINDER, /if missing, request "resend":true and wait/);
  assert.ok(L.LIMIT_REMINDER.length < 550, "Keep the formatting and source-text reminders short enough for 1,000-character reply parts.");
  const full = 'A quoted line: "hello".\n'.repeat(100);
  const parts = L.splitReply(full, 1000);
  assert.ok(parts.length > 1);
  assert.ok(parts.every((p) => p.length <= 1000 && p.endsWith(L.LIMIT_REMINDER)));
  assert.equal(parts.map((p) => p.split("--- BEGIN PART ---\n")[1].split("\n--- END PART ---")[0]).join(""), full);
});

test("splitting", () => {
  const parts = L.splitReply("x\n".repeat(150000), 100000);
  assert.ok(parts.length===4 && parts.every(p=>p.length<=100000));
});

test("agent JSON", () => {
  assert.deepEqual(L.parseAgentJSON('Sure, here it is:\n```json\n{"type":"atlas-request","requests":[]}\n```\nDone.'), { type: "atlas-request", requests: [] });
  const whole = JSON.stringify({ type: "atlas-change", summary: "x".repeat(50) });
  const part = (n, text) => JSON.stringify({ type: "atlas-response-part", id: "a", part: n, total: 2, text });
  const pasted = part(2, whole.slice(20)) + "\n\nand\n\n" + part(1, whole.slice(0, 20));
  assert.equal(L.parseAgentJSON(pasted).summary, "x".repeat(50));
  assert.throws(() => L.parseAgentJSON(part(1, whole.slice(0, 20))), /Part 2 of 2 is missing/);
  assert.throws(() => L.parseAgentJSON('{"type":"atlas-request"'), /incomplete/);
  assert.throws(() => L.parseAgentJSON("no json here"), /No JSON found/);
});

test("serialized code proposals preserve quotes, apostrophes, escapes and whitespace when copied", () => {
  const find = "const message = \"Don't change this.\";\r\n\tconst pattern = /\\w+\\s*/g;\r\n";
  const replace = find.replace("this.", "that.");
  const proposal = {type:"atlas-change",change:"CHG-1",files:[
    {path:"lwc/sample/history.js",edits:[{find,replace}]},
    {path:"lwc/sample/helper.js",content:'export const newline = "\\n";\n'},
  ]};
  const serialized = JSON.stringify(proposal);
  assert.deepEqual(JSON.parse(serialized), proposal);
  for (const pasted of [serialized, "Here is the proposal:\n```json\n" + serialized + "\n```"]) {
    assert.deepEqual(L.parseAgentJSON(pasted), proposal);
  }
  const broken = serialized.replace('\\"', '"');
  assert.throws(() => L.parseAgentJSON("```json\n" + broken + "\n```"), /not valid|incomplete/,
    "Invalid escaping must be rejected, not repaired by changing the source.");
});

test("separately serialized JSON parts preserve code even when a cut splits an escape", () => {
  const code = 'console.log("Don\'t remove quotes or \\slashes");\n\t'.repeat(500);
  const proposal = {type:"atlas-change",change:"CHG-1",files:[{path:"lwc/sample/history.js",content:code}]};
  const serialized = JSON.stringify(proposal);
  assert.deepEqual(JSON.parse(serialized), proposal);
  assert.ok(serialized.length > L.AGENT_LIMIT);
  const cut = serialized.indexOf('\\"') + 1;
  const chunks = [serialized.slice(0, cut)];
  for (let start = cut; start < serialized.length; start += 2000) chunks.push(serialized.slice(start, start + 2000));
  const parts = chunks.map((text, i) => {
    const envelope = JSON.stringify({type:"atlas-response-part",id:"code-1",part:i+1,total:chunks.length,text});
    assert.equal(JSON.parse(envelope).text, text);
    const fenced = "```json\n" + envelope + "\n```";
    assert.ok(fenced.length <= L.AGENT_LIMIT);
    return fenced;
  });
  assert.deepEqual(L.parseAgentJSON(parts.join("\n\n")), proposal);
  assert.deepEqual(L.parseAgentJSON(parts.map((p) => p.slice(8, -4)).join("\n\n")), proposal,
    "The code block Copy button may omit fences.");
});

test("the documented small-part recipe preserves long Files and UAT JSON within the reply budget", () => {
  const content = 'Check "quoted" values, C:\\fixture\\path, tabs\tand newlines\nwith emoji 🧪. '.repeat(600);
  for (const type of ["atlas-files", "atlas-uat-plan"]) {
    const message = type === "atlas-files"
      ? {type, artifacts:[{kind:"docx",name:"Long.docx",blocks:[{type:"paragraph",text:content}]}]}
      : {type, requestId:"conversation-1", title:"Long plan", summary:content};
    const serialized = JSON.stringify(message);
    assert.ok(serialized.length > L.AGENT_LIMIT * 2);
    const pieces = [];
    for (let start = 0; start < serialized.length; start += 1800) pieces.push(serialized.slice(start, start + 1800));
    const responses = pieces.map((text, index) => {
      const json = JSON.stringify({type:"atlas-response-part",id:"document-1",part:index+1,total:pieces.length,text});
      assert.equal(JSON.parse(json).text, text);
      return "```json\n" + json + "\n```";
    });
    assert.ok(responses.every((text) => text.length <= 12000));
    assert.deepEqual(L.parseAgentJSON(responses.join("\n\n")), message);
    assert.throws(() => L.parseAgentJSON(responses.slice(0, -1).join("\n\n")), /missing/);
  }
});

test("agent JSON after a code block that is not JSON", () => {
  const request = { type: "atlas-request", requests: [{ op: "soql", query: "SELECT Id FROM Case" }] };
  const reply = "I'd check this first:\n```bash\nsf data query -q 'SELECT Id FROM Case'\n```\nHere is the request:\n```json\n  " + JSON.stringify(request) + "\n```";
  assert.deepEqual(L.parseAgentJSON(reply), request);
  assert.deepEqual(L.parseAgentJSON("```\nnot json\n```\n" + JSON.stringify(request)), request);
  assert.throws(() => L.parseAgentJSON("```bash\nls\n```\nno JSON after it"), /No JSON found/);
  assert.throws(() => L.parseAgentJSON("```json\nunfinished"), /No JSON found after the code fence/);
});

test("multipart totals are bounded before enumerating missing parts", () => {
  assert.throws(() => L.parseAgentJSON(JSON.stringify({type:"atlas-response-part", id:"a", part:1, total:1001, text:"{"})), /at most 1000 parts/);
});

test("limits", () => {
  assert.equal(L.DEFAULT_REPLY_LIMIT, 100000);
  assert.equal(L.replyLimit(undefined), 100000);
  assert.equal(L.replyLimit(20000), 20000);
  assert.equal(L.replyLimit(5), 100000);
  assert.deepEqual(L.splitReply("short", 100000), ["short"]);
  const reminder = L.rulesReminder({ conversation: { mode: "Task", title: "T" }, boot: { user: { name: "Chance" }, people }, mine: {}, jira: {} });
  assert.ok(reminder.includes("14,000"));
});

test("Jira update text", () => {
  const text = L.updateText({ changes: { assignee: "acc-rob", assigneeId: "P2", dueDate: null }, comments: ["one", "two"] });
  assert.equal(text, "Change in Jira:\nassignee: acc-rob\ndueDate: (clear it)\n\nComment:\none\n\ntwo");
  assert.equal(L.updateText({ changes: {}, comments: [] }), "");
});

test("download types Lightning allows", () => {
  assert.equal(L.blobType("text/csv;charset=utf-8"), "application/octet-stream");
  assert.equal(L.blobType("application/vnd.openxmlformats-officedocument.wordprocessingml.document"), "application/octet-stream");
  assert.equal(L.blobType("application/zip"), "application/zip");
  assert.equal(L.blobType("text/plain; charset=utf-8"), "text/plain");
  assert.equal(L.blobType(undefined), "application/octet-stream");
});

test("query replies retain incomplete child cursors and COUNT results", () => {
  const query = {id: "q", op: "soql"};
  const text = L.resultText(query, {maxRows: 200, pages: [{totalSize: 1, done: true, records: [{Id: "parent", Contacts: {totalSize: 5, done: false, nextRecordsUrl: "/services/data/v67.0/query/children", records: [{Id: "child", attributes: {}}]}}]}]});
  assert.match(text, /"done":false/);
  assert.match(text, /"nextRecordsUrl":"\/services\/data\/v67.0\/query\/children"/);
  assert.match(text, /"totalSize":5/);
  assert.doesNotMatch(text, /attributes/);
  const count = L.resultText(query, {maxRows: 200, pages: [{totalSize: 321, done: true, records: []}]});
  assert.match(count, /COUNT\(\): 321/);
  assert.doesNotMatch(count, /0 of 321|add filters/);
});

test("activity replies expose incomplete sources separately from read errors", () => {
  const text = L.resultText({id: "activity", op: "activity"}, {count: 0, days: 7, people: ["Tester"], rows: [],
    skipped: ["Flow: inaccessible"], limited: ["ApexClass: showing the latest 200 items; more match this period."], note: "Evidence only."});
  assert.match(text, /Could not read: Flow: inaccessible/);
  assert.match(text, /INCOMPLETE sources: ApexClass: showing the latest 200/);
  assert.match(text, /Evidence only/);
});

test("uncertain deployment replies prohibit blind retries for both operations", () => {
  for (const operation of ["deploy", "restore"]) {
    const text = L.deployReply({name: "CHG-7", revision: 2, status: operation === "restore" ? "Restoring" : "Deploying", result: {operation, outcomeUnknown: true, errorMessage: "Response lost"}});
    assert.match(text, /UNKNOWN/);
    assert.match(text, /Deployment Status/);
    assert.match(text, /Do not retry/);
    assert.doesNotMatch(text, /Nothing changed|DEPLOY FAILED|restore FAILED|corrected atlas-change/);
  }
});

test("deploy and restore replies", () => {
  const change = { name: "CHG-7", revision: 2, decisionNote: "ship it" };
  const deployed = L.deployReply({ ...change, status: "Deployed", result: { testsRun: "3", operation: "deploy" } });
  assert.match(deployed, /I approved and DEPLOYED CHG-7 revision 2\.\n3 Apex test\(s\) ran and passed\.\nMy note: ship it/);
  const failed = L.deployReply({ ...change, status: "Failed", result: { operation: "deploy", componentErrors: [{ file: "classes/A.cls", line: "4", problem: "bad" }] } });
  assert.match(failed, /DEPLOY FAILED[\s\S]*classes\/A\.cls line 4: bad[\s\S]*"change":"CHG-7"/);
  for (const reply of [deployed, failed]) assert.doesNotMatch(reply, /Exact Salesforce|"operation"|\{\n/, "No raw result JSON");
  const pending = L.deployReply({ ...change, status: "Deploying", result: { operation: "deploy", resultUnknown: true, status: "InProgress", id: "0Af" } });
  assert.match(pending, /NOT YET CONFIRMED: Salesforce has not returned a final result \(InProgress\)[\s\S]*Do not resubmit/);
  assert.doesNotMatch(pending, /"id"|0Af/);
  const restoreChange = L.deployReply({ name: "CHG-9", revision: 1, summary: "Restore ApexClass Foo to v1 (Original)", restoreFrom: "a01", status: "Restored",
    result: { operation: "restore", success: "true", componentWarnings: [{ file: "classes/Foo.cls", line: "3", problem: "deprecated" }] } });
  assert.match(restoreChange, /^I RESTORED Restore ApexClass Foo to v1 \(Original\) \(CHG-9\)\.\nNo Apex tests ran\.\nSalesforce warnings:\n- classes\/Foo\.cls line 3: deprecated/);
  const restored = L.deployReply({ ...change, status: "Restored", result: { operation: "restore", success: "true" } });
  assert.match(restored, /I RESTORED CHG-7 revision 2\./);
  assert.match(restored, /does not delete components created later/);
  assert.match(restored, /earlier backups of them are out of date/);
  assert.doesNotMatch(restored, /ship it/);
  for (const status of ["Deployed", "Restored"]) {
    const restoreFailed = L.deployReply({ ...change, status, result: { operation: "restore", success: "false", errorMessage: "locked" } });
    // A failed restore keeps the earlier status, even when that status was Restored.
    assert.match(restoreFailed, /RESTORE FAILED for CHG-7[\s\S]*locked\nNothing was restored\./);
    assert.doesNotMatch(restoreFailed, /approved|corrected|I RESTORED/i);
  }
});
