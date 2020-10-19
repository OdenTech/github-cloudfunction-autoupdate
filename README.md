# github-cloudfunction-autoupdate

To my intense frustration, while you can deploy a google cloud function
using a google cloud source repo as its source, and you can point it to
a moveable function (a branch or a tag name) inside the repo, if the
target of that ref is updated the cloud function does not detect the update
and redeploy automatically.

Worse yet, function instances are regional resources, so you can't just
mash the "re-update" button -- you have to figure out which region(s) the
function is currently deployed to and PATCH the running resource.

So, this github action. We do a number of things in order:

1. Get a list of all deployed cloudfunctions in all regions, sort them
   into an associative array of funcname->region[,region...]

2. Get the list of functions we manage in this repo, assumed to be
   the list of directory names in $FUNCTIONS_DIR/

3. For each function we manage in this repo, if we previously found
   a corresponding function deployed in step 1, then for each region
   in which we found it running:

    a. Pull down the JSON document representing the current function state

    b. PATCH that document back up to the google API, and set the 'updateMask'
       parameter to the sourceRepository.url field, which tells google that
       it needs to re-resolve which git SHA the ref name points at

    c. Get the operation ID returned by the PATCH API

4. Wait for all PATCH operations to complete and flag any errors.
