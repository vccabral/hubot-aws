# Description:
#   List ec2 instances info
#   Show detail about an instance if specified an instance id
#   Filter ec2 instances info if specified an instance name
# Configurations:
#   HUBOT_AWS_DEFAULT_CREATOR_EMAIL: [required] An email address to be used for tagging the new instance
#
# Commands:
#   hubot ec2 ls - Displays Instances
#   hubot ec2 ls instance_id - Displays details about 'instance_id'
#   hubot ec2 mine - Displays Instances I've created, based on user email
#   hubot ec2 chat - Displays Instances created via chat
#   hubot ec2 filter sometext - Filters instances starting with 'sometext'

gist = require 'quick-gist'
moment = require 'moment'
_ = require 'underscore'
tsv = require 'tsv'

EXPIRED_MESSAGE = "Instances that have expired \n"
EXPIRES_SOON_MESSAGE = "Instances that will expire soon \n"
USER_EXPIRES_SOON_MESSAGE = "List of your instances that will expire soon: \n"
EXTEND_COMMAND ="\nIf you wish to extend run 'cfpbot ec2 extend [instanceIds]'"
DAYS_CONSIDERED_SOON = 2

ec2 = require('../../ec2.coffee')

getInstancesFromArg=(arg)->
  instances = []
  if arg
    for av in arg.split /\s+/
      if av and not av.match(/^--/)
        instances.push(av)
  return instances

getParamsFromFilter = (filter, opt_arg, instances)->
  params = {}
  if filter == "mine"
    params['Filters'] = [{Name: 'tag:Creator', Values: [opt_arg]}]
  else if filter == "chat"
    params['Filters'] = [{Name: 'tag:CreatedByApplication', Values: [filter]}]
  else if filter == "filter" and instances.length
    params['Filters'] = [{ Name: 'tag:Name', Values: ["*#{instances[0]}*"] }]
  else if instances.length
    params['InstanceIds'] = instances
  else
    return null
  return params


getArgParams = (arg, filter = "all", opt_arg = "") ->
  instances = getInstancesFromArg(arg)
  params = getParamsFromFilter(filter, opt_arg, instances)
  return params

getInstancesFromReservation=(reservation) ->
  instances = []

  for reservation in res.Reservations
    for instance in reservation.Instances
      instances.push(instance)

  return instances

get_instance_tag = (instance, key, default_value = "")->
  tags = _.filter(instance.Tags, (tag)-> return tag.Key == key)
  if not _.isEmpty(tags)
    return tags[0].Value
  else
    return default_value

listEC2Instances = (params, complete, error) ->
  ec2.describeInstances params, (err, res) ->
    if err
      error(err)
    else
      complete(instances)

instance_will_expire_soon = (instance) ->
  expiration_tag = get_instance_tag(instance, "ExpireDate", false)

  unless expiration_tag
    return false

  expiraton_moment = moment(expiration_tag).format('YYYY-MM-DD')

  will_be_expired_in_x_days = expiraton_moment < moment().add(DAYS_CONSIDERED_SOON, 'days').format('YYYY-MM-DD')
  is_not_expired_now = expiraton_moment < moment().format('YYYY-MM-DD')

  return will_be_expired_in_x_days and not is_not_expired_now

instance_has_expired = (instance) ->
  expiration_tag = get_instance_tag(instance, "ExpireDate", false)
  unless expiration_tag
    return false

  expiraton_moment = moment(expiration_tag[0].Value).format('YYYY-MM-DD')

  is_not_expired_now = expiraton_moment < moment().format('YYYY-MM-DD')

  return is_not_expired_now

messages_from_ec2_instances = (instances) ->

  messages = []
  for instance in instances
    name = '[NoName]'
    for tag in instance.Tags when tag.Key is 'Name'
      name = tag.Value

    messages.push({
      time: moment(instance.LaunchTime).format('YYYY-MM-DD HH:mm:ssZ')
      state: instance.State.Name
      id: instance.InstanceId
      image: instance.ImageId
      az: instance.Placement.AvailabilityZone
      subnet: instance.SubnetId
      type: instance.InstanceType
      ip: instance.PrivateIpAddress
      name: name || '[NoName]'
    })

  messages.sort (a, b) ->
    moment(a.time) - moment(b.time)
  return tsv.stringify(messages) || '[None]'

extract_message = (instances, msg)->
  return msg + messages_from_ec2_instances(instances)


get_msg_room_from_robot = (robot) ->
  return (msg_text, room = process.env.HUBOT_EC2_MENTION_ROOM) ->
    robot.messageRoom room, msg_text

get_msg_user_from_robot = (robot) ->
  return (user_id, msg) ->
    robot.send({user: user_id}, msg)

ec2_stop_instances = (ec2, params, msg_room) -> 
  ec2.stopInstances params, (err, res) ->
    if err
      msg_room(res)

getStopParamsFromInstances = (instances)->
  return {InstanceIds: _.pluck(instances, 'InstanceId')}

handle_instances_with_message_controler = (robot, msg_room, msg_user, ec2_stop_instances) ->
  instances_that_expired = instances.filter instance_has_expired
  instances_that_will_expire = instances.filter instance_will_expire_soon

  msg_text_expired = extract_message(instances_that_expired, EXPIRED_MESSAGE)
  msg_text_expire_soon = extract_message(instances_that_will_expire, EXPIRES_SOON_MESSAGE)

  msg_room(msg_text_expired)
  msg_room(msg_text_expire_soon)

  for user in _.values(robot.brain.data.users)
    creator_email = user.email_address || "_DL_CFPB_Software_Delivery_Team@cfpb.gov"
    user_id = user.id || 1

    user_instances = _.filter(instances_that_will_expire, (this_instance)-> return get_instance_tag(this_instance, 'Creator') == creator_email)

    if user_instances
      msg_text_expire_soon = extract_message(user_instances, USER_EXPIRES_SOON_MESSAGE) + EXTEND_COMMAND

      msg_user(user_id, msg_text_expire_soon)

  stop_instance_ids_params = getStopParamsFromInstances(instances_that_expired)
  ec2_stop_instances(ec2, stop_instance_ids_params, msg_room)

handle_instances = (robot) ->
  msg_room = get_msg_room_from_robot(robot)
  msg_user = get_msg_user_from_robot(robot)
  return handle_instances_with_message_controler(robot, msg_room, msg_user, ec2)


handle_ec2_instance = (robot) ->
  if process.env.HUBOT_EC2_MENTION_ROOM
    params = getArgParams(null, filter = "chat")
    listEC2Instances(params, handle_instances(robot), ->)

ec2_setup_polling = (robot) ->
  setInterval ->
    handle_ec2_instance(robot)?
  , 1000 * 60 * 60 * 8

error_ec2_instances = (msg, err) ->
  return (err) ->
    msg.send "DescribeInstancesError: #{err}"

complete_ec2_instances = (msg, instances) ->
  return (instances) ->

    msgs = messages_from_ec2_instances(instances)
    if msgs.length < 1000
      msg.send msgs
    else
      gist {content: msgs, enterpriseOnly: true}, (err, resp, data) ->
        url = data.html_url
        msg.send "View instances at: " + url

module.exports = (robot) ->

  ec2_setup_polling(robot)

  robot.respond /ec2 ls(.*)$/i, (msg) ->
    arg_params = getArgParams(arg = msg.match[1])
    msg.send "Fetching instances..."

    listEC2Instances(arg_params, complete_ec2_instances(msg), error_ec2_instances(msg))

  robot.respond /ec2 filter(.*)$/i, (msg) ->
    arg_params = getArgParams(arg = msg.match[1], filter = "filter")
    msg.send "Fetching filtered instances..."

    listEC2Instances(arg_params, complete_ec2_instances(msg), error_ec2_instances(msg))

  robot.respond /ec2 mine$/i, (msg) ->
    creator_email = msg.message.user["email_address"] || process.env.HUBOT_AWS_DEFAULT_CREATOR_EMAIL || "unknown"
    msg.send "Fetching instances created by #{creator_email} ..."
    arg_params = getArgParams(arg = msg.match[1], filter = "mine", opt_arg = creator_email)

    listEC2Instances(arg_params, complete_ec2_instances(msg), error_ec2_instances(msg))


  robot.respond /ec2 chat$/i, (msg) ->
    msg.send "Fetching instances created via chat ..."
    arg_params = getArgParams(arg = msg.match[1], filter = "chat")

    listEC2Instances(arg_params, complete_ec2_instances(msg), error_ec2_instances(msg))

