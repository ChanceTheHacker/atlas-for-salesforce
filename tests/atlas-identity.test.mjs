import test from "node:test";
import assert from "node:assert/strict";
import {readFile, mkdtemp, rm} from "node:fs/promises";
import {tmpdir} from "node:os";
import {join} from "node:path";
import {build} from "esbuild";

const root = new URL("../salesforce/force-app/main/default/lwc/", import.meta.url).pathname;
const dir = await mkdtemp(join(tmpdir(), "atlas-identity-"));
const components = {};
for (const name of ["atlasTeam", "atlasConversation", "atlasLib"]) {
  const outfile = join(dir, name + ".mjs");
  await build({entryPoints:[join(root, name, name + ".js")], bundle:true, platform:"node", format:"esm", outfile,
    plugins:[{name:"platform", setup(b) {
      b.onResolve({filter:/^lwc$|^lightning\/|^@salesforce\//}, ({path})=>({path,namespace:"platform"}));
      b.onLoad({filter:/.*/,namespace:"platform"}, ({path})=>({contents:path==="lwc"
        ? "export class LightningElement { dispatchEvent() {} } export const api=()=>{};"
        : path.startsWith("@salesforce/apex/") ? `export default args=>globalThis.identityApex(${JSON.stringify(path.split("/").at(-1))},args);`
          : path.startsWith("lightning/") ? "export const loadScript=async()=>{};" : "export default 'resource';"}));
      b.onResolve({filter:/^c\//}, ({path})=>({path:join(root,path.slice(2),path.slice(2)+".js")}));
      b.onLoad({filter:/\/atlas[^/]+\/atlas[^/]+\.js$/}, async ({path})=>({contents:(await readFile(path,"utf8")).replace(/@api\s+/g,""),loader:"js"}));
    }}]});
  components[name] = await import(outfile);
}
await rm(dir,{recursive:true});
const Team = components.atlasTeam.default, Conversation = components.atlasConversation.default, lib=components.atlasLib;
const click = (id)=>({preventDefault(){},currentTarget:{dataset:{id}}});
const deferred=()=>{let resolve,reject; const promise=new Promise((a,b)=>{resolve=a;reject=b;});return {promise,resolve,reject};};
const person={id:"person1", name:"Christopher Example", userName:"Christopher Example", userId:"005user1", jiraId:"sso-chris", email:"chris@example.com", aliases:["Chris","CJ","Chris from support"], active:true};

test("all person identifiers resolve to the same person and namespace collisions do not guess",()=>{
  for (const value of [person.id, person.userId, person.jiraId, person.name, person.email, " CHRIS   FROM SUPPORT ", "CJ"])
    assert.equal(lib.findPerson([person],value),person,value);
  assert.equal(lib.findPerson([person,{id:"other",name:"CJ",jiraId:"other-jira"}],"CJ"),null);
  assert.equal(lib.findPerson([{...person,identityWarning:"SSO changed"}],"Chris"),null);
  assert.equal(lib.findPerson([{...person,active:false}],"Chris"),null);
  const batch=lib.checkTicketBatch({tickets:[{ref:"T1",summary:"Case followup",assignee:"Chris"}]},{people:[person]});
  assert.deepEqual(batch.errors,[]); assert.equal(batch.batch.tickets[0].assigneeId,person.id);
});

test("agent context distinguishes Salesforce ownership, Jira identity and Atlas person IDs",()=>{
  const text=lib.peopleContext([person]);
  for (const value of [person.id,person.userId,person.jiraId,person.email,"CJ"]) assert.ok(text.includes(value),value);
  const settings=lib.readSettings({settings:{identity:'{"ssoField":"FederationIdentifier"}'}});
  assert.equal(settings.identity.ssoField,"FederationIdentifier");
  assert.ok(lib.OPS.includes("users")); assert.ok(lib.MESSAGE_TYPES.includes("atlas-assign"));
  const prompt=lib.firstPrompt({conversation:{mode:"Task"},boot:{people:[person],org:{},user:{}},mine:settings.mine,jira:settings.jira});
  assert.match(prompt,/"op":"users"|users: "term"/); assert.match(prompt,/NOT one atomic transaction/);
});

test("one Salesforce selection fills the SSO Jira ID and saves all names together",async()=>{
  const c=new Team(); c.boot={people:[]}; c.settings={identity:{ssoField:"FederationIdentifier"}}; c.addPerson();
  c.person.aliases="Chris\nCJ\nChris from support\nChristopher\nC. Example";
  c.userResults=[{id:person.userId,userName:person.name,ssoId:person.jiraId,active:true}]; c.pickUser(click(person.userId));
  assert.equal(c.person.jiraId,person.jiraId); assert.equal(c.person.userId,person.userId);
  let saved;
  globalThis.identityApex=async(name,args)=>{assert.equal(name,"Atlas_Data.savePerson");saved=JSON.parse(args.personJson);return "person1";};
  await c.submitPerson(); assert.equal(saved.aliases.length,5); assert.equal(saved.jiraId,person.jiraId); assert.equal(c.person,null);
});

test("late Salesforce lookups cannot replace a newer search or a different person editor",async()=>{
  const c=new Team(); c.boot={people:[]}; c.addPerson();
  const a=deferred(),b=deferred(); let calls=0;
  globalThis.identityApex=async()=>++calls===1?a.promise:b.promise;
  const first=c.searchUsers({detail:{value:"Chris"}}),second=c.searchUsers({detail:{value:"Casey"}});
  b.resolve(JSON.stringify({status:"resolved",matches:[{userId:"casey",userName:"Casey",active:true}]}));await second;
  a.resolve(JSON.stringify({status:"resolved",matches:[{userId:"chris",userName:"Chris",active:true}]}));await first;
  assert.equal(c.userResults[0].id,"casey");
  const late=deferred();globalThis.identityApex=async()=>late.promise;
  const work=c.searchUsers({detail:{value:"Chris"}});c.cancelPerson();c.addPerson();late.reject(Error("old lookup error"));await work;
  assert.deepEqual(c.userResults,[]);assert.equal(c.error,undefined);
});

test("adding people does not require the current user to have an SSO identity",async()=>{
  const html=await readFile(join(root,"atlasTeam","atlasTeam.html"),"utf8");
  assert.doesNotMatch(html, /<template lwc:if=\{me\}>\s*<lightning-button label="Add a person"/);
  assert.match(html, /label="Add a person"/);
});

test("a duplicate Salesforce link directs the user to add aliases on the existing person",()=>{
  const c=new Team();c.boot={people:[person]};c.addPerson();c.userResults=[{id:person.userId,userName:person.name,active:true}];
  c.pickUser(click(person.userId));assert.match(c.error,/already links/);assert.equal(c.person.userId,"");
});

test("Case review does not mutate; a lost decision response survives reload and retries exact consent",async()=>{
  const c=new Conversation();c.conversationId="conv";c.settings={mine:{replyLimit:100000}};
  const review=[{caseId:"500case",caseNumber:"100",oldOwnerId:"old",userId:person.userId,name:person.name}];
  let durable,decisions=[],failed=false;
  c.persistDraft=async()=>{durable=structuredClone(c.draftData());};c.load=async()=>{};
  globalThis.identityApex=async(name,args)=>{
    if(name==="Atlas_Assignments.prepare")return JSON.stringify(review);
    assert.equal(name,"Atlas_Assignments.decide");assert.equal(durable.assignmentDecision.nonce,args.nonce);
    decisions.push(args);if(!failed){failed=true;throw Error("lost response");}return "applied receipt";
  };
  await c.reviewAssignments({cases:[{caseId:"500case",assignee:"Chris",reason:"Requested"}]});assert.equal(decisions.length,0);
  c.assignmentNote="Approved support owner";await c.approveAssignments();assert.equal(decisions.length,1);assert.ok(c.assignmentDecision);
  const next=new Conversation();next.conversationId="conv";next.settings=c.settings;next.applyDraft(durable);next.load=async()=>{};
  next.persistDraft=async()=>{durable=structuredClone(next.draftData());};
  next.handleAssignmentNote({detail:{value:"must not change"}});await next.retryAssignments();
  assert.deepEqual(decisions[1],decisions[0]);assert.equal(next.assignmentReview,null);assert.equal(next.assignmentDecision,null);
});

test("confirmed alias replies keep Salesforce user IDs separate from Jira IDs",async()=>{
  const c=new Conversation();c.conversationId="conv";c.boot={people:[person]};
  c.identities=[{alias:"CJ",personId:person.id}];
  globalThis.identityApex=async(name)=>name==="Atlas_Identity.lookup"
    ? JSON.stringify({resolved:{...person,personId:person.id}}) : person.id;
  let reply;c.send=async(kind,text)=>{reply=JSON.parse(text.slice(0,text.lastIndexOf("\n")));};
  await c.sendIdentities();
  assert.equal(c.problem,null);
  assert.equal(reply.users[0].userId,person.userId);
  assert.equal(reply.users[0].jiraId,person.jiraId);
  assert.equal(reply.users[0].personId,person.id);
});

test("uncertain Case decisions cannot be replaced by another agent proposal",async()=>{
  const c=new Conversation();c.assignmentReview=[{caseId:"saved"}];
  await assert.rejects(c.reviewAssignments({cases:[]}),/Finish the current/);
});
