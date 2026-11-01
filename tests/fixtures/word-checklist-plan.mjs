// Synthetic acceptance-plan fixture: no customer data, org access, or live actions.
const scenarios = [
  {
    title: "Create a service request with all required fields",
    role: "Service coordinator",
    setup:
      "Use a synthetic account named Atlas Training Account and a clean browser session. Confirm that no request already exists with the reference UAT-REQ-001.",
    steps: [
      "Open the service request workspace and choose New request. Confirm the blank form identifies required fields before entering any values.",
      "Enter reference UAT-REQ-001, select the training account, and enter a description containing an ampersand and angle brackets: Parts & service <priority review>.",
      "Select Normal priority and assign the request to the training service queue. Save once and wait for the confirmation message before navigating away.",
      "Reopen the saved request from the list. Compare the reference, description, priority, and owner with the submitted values, including all punctuation.",
    ],
    expected:
      "Exactly one request is created. All submitted values are retained, and the request appears in the correct queue without revealing another team's records.",
  },
  {
    title: "Reject missing required information without losing input",
    role: "Service coordinator",
    setup:
      "Start a new unsaved request using reference UAT-REQ-002. Keep the browser session open so that the entered values can be checked after validation fails.",
    steps: [
      "Enter the reference and description, but leave the account field empty. Select Save and observe the validation message without dismissing the form.",
      "Confirm the missing account is named in plain language and keyboard focus reaches the field. Check that the description and reference are still present.",
      "Select the training account, leave another required field empty, and repeat the save. Confirm the message identifies the current issue rather than an earlier error.",
      "Complete all required fields and save. Search for UAT-REQ-002 and verify that unsuccessful attempts did not create partial or duplicate records.",
    ],
    expected:
      "Invalid submissions create no records. The form preserves entered values, identifies missing information, and succeeds only after all required data is supplied.",
  },
  {
    title: "Prevent an unauthorized reviewer from changing ownership",
    role: "Read-only reviewer",
    setup:
      "Use the designated training reviewer account with read access but no ownership-edit permission. An authorized coordinator must prepare UAT-REQ-003 in advance.",
    steps: [
      "Sign in as the reviewer and open UAT-REQ-003. Record the current owner and status in the evidence notes before inspecting the available actions.",
      "Check whether the ownership field is read-only and whether editing actions are absent or disabled. Do not substitute an administrator session for this check.",
      "Use any existing bookmarked edit route for the training request. Confirm the application refuses the edit rather than relying only on a hidden button.",
      "Return to the request details and refresh. Ask the coordinator to verify separately that the owner, status, and audit history remain unchanged.",
    ],
    expected:
      "The reviewer can read permitted information but cannot change ownership through the form or a direct edit route. No unauthorized update is recorded.",
  },
  {
    title: "Preserve the original record when two people edit concurrently",
    role: "Two service coordinators",
    setup:
      "Open UAT-REQ-004 in two separate training sessions. Both coordinators should begin with the same status and description and use distinct evidence references.",
    steps: [
      "In the first session, change the priority to High and save. Confirm the successful update before making any changes in the second session.",
      "In the second session, change the description using the stale form and attempt to save. Capture the exact conflict or refresh message shown to the user.",
      "Follow the documented refresh or review action. Compare the latest priority and description with both coordinators' intended changes before retrying.",
      "Save the reviewed update only once. Reopen the request in both sessions and compare the final values with the agreed result and audit history.",
    ],
    expected:
      "The stale edit never silently overwrites the first coordinator's work. The user receives enough information to review and deliberately resolve the conflict.",
  },
  {
    title: "Recover safely after a save response is interrupted",
    role: "Service coordinator",
    setup:
      "Use only the approved test environment and request UAT-REQ-005. Simulate the interrupted response using the test harness, not by changing shared network settings.",
    steps: [
      "Prepare a complete request and enable the approved interrupted-response scenario. Save once, and record whether the interface reports an uncertain result.",
      "Before retrying, reopen the request list and search for the unique reference. If a saved record exists, open it instead of creating a replacement.",
      "Use the application's recovery or retry action only when instructed by the interface. Record how the interface distinguishes an unsaved draft from a saved request.",
      "Restore the normal test connection, refresh the list, and count matching records. Compare the surviving request's fields with the original submitted values.",
    ],
    expected:
      "The application explains uncertainty honestly. Recovery preserves submitted content and does not create a duplicate when the first save already succeeded.",
  },
  {
    title: "Complete the review using keyboard navigation and long notes",
    role: "Acceptance reviewer",
    setup:
      "Prepare UAT-REQ-006 with a multi-paragraph description and a long evidence reference. Use keyboard navigation throughout the primary review sequence.",
    steps: [
      "Navigate from the request list to the details view without using a pointer. Confirm focus order follows the visible reading order and every action has a clear name.",
      "Read the full description and evidence notes at an enlarged text setting. Confirm content wraps without covering controls or hiding the last lines.",
      "Enter review notes containing café, quotation marks, and Parts & service <review>. Move between fields and return to confirm the text remains unchanged.",
      "Complete the review, reopen the record, and verify all notes. Capture any focus trap, clipped text, missing label, or unexpected scroll behavior as a defect.",
    ],
    expected:
      "The full review can be completed with a keyboard. Long notes remain readable and correctly stored, including punctuation and accented characters.",
  },
];

export const checklistPlan = {
  kind: "docx",
  name: "Service-Request-UAT-Checklist.docx",
  title: "Service request acceptance test plan",
  blocks: [
    { type: "heading", level: 1, text: "Service request acceptance test plan" },
    {
      type: "paragraph",
      text: "Synthetic training example • Release candidate 2026.10 • Prepared for the acceptance review team. This sample does not certify a live system or contain customer information.",
    },
    {
      type: "table",
      headers: ["Plan detail", "Value"],
      rows: [
        ["Environment", "Training sandbox only"],
        ["Coordinator", "Training service team"],
        ["Execution window", "Agree before testing"],
        [
          "Evidence",
          "Record screenshots and defect references in the approved test workspace",
        ],
      ],
    },
    { type: "heading", level: 2, text: "Readiness and execution guidance" },
    {
      type: "paragraph",
      text: "Complete the readiness checks before running the scenarios. A checked box records a verified condition, not an assumption. Leave a box unchecked when its condition is not met and explain the reason in the notes. A previously checked readiness item below is illustrative only.",
    },
    {
      type: "checklist",
      items: [
        {
          text: "Synthetic test records and the training environment are identified.",
          checked: true,
        },
        {
          text: "The test coordinator has confirmed the release candidate and execution window.",
        },
        {
          text: "The reviewer accounts have the required distinct permission levels.",
          checked: false,
        },
        {
          text: "Evidence storage is available and contains no production credentials or customer data.",
        },
      ],
    },
    ...scenarios.flatMap((scenario, i) => [
      {
        type: "heading",
        level: 1,
        text: `UAT-${String(i + 1).padStart(2, "0")}: ${scenario.title}`,
      },
      {
        type: "paragraph",
        runs: [{ text: "Tester role: ", bold: true }, { text: scenario.role }],
      },
      {
        type: "paragraph",
        runs: [
          { text: "Preconditions: ", bold: true },
          { text: scenario.setup },
        ],
      },
      { type: "heading", level: 2, text: "Steps" },
      { type: "numbered", items: scenario.steps },
      {
        type: "paragraph",
        runs: [
          { text: "Expected result: ", bold: true },
          { text: scenario.expected },
        ],
      },
      {
        type: "checklist",
        items: [
          {
            text: "All listed steps were executed with the specified role and training data.",
          },
          {
            text: "The observed result matches the expected result, including the negative checks.",
          },
          {
            text: "Evidence has been recorded and any defect has an assigned reference.",
          },
        ],
      },
      {
        type: "paragraph",
        text: "Actual result: __________________________________________________________________________________",
      },
      {
        type: "paragraph",
        text: "Notes and evidence: Record the request reference, tester, execution time, observed behavior, and any difference from the expected result. If blocked, state the missing prerequisite and who can resolve it.",
      },
      {
        type: "table",
        headers: ["Tester and date", "Evidence or defect reference", "Outcome"],
        rows: [
          [
            "________________",
            "________________________",
            "Not run / Pass / Fail / Blocked",
          ],
        ],
      },
    ]),
    { type: "heading", level: 1, text: "Completion and acceptance" },
    {
      type: "paragraph",
      text: "The coordinator must review evidence and unresolved defects before recommending acceptance. Do not treat unchecked conditions as passed. A release decision belongs to the authorized owner and is not implied by generating this document.",
    },
    {
      type: "checklist",
      items: [
        {
          text: "Every scenario has an actual result, named tester, and evidence reference.",
        },
        {
          text: "Failed or blocked scenarios have been retested or explicitly accepted by the authorized owner.",
        },
        {
          text: "Training records are accounted for and no production data was changed.",
        },
        {
          text: "The acceptance decision, approver, and date are recorded below.",
        },
      ],
    },
    {
      type: "paragraph",
      text: "Decision and approver: __________________________________________________________________________",
    },
    {
      type: "paragraph",
      text: "Final notes: ____________________________________________________________________________________",
    },
  ],
};
