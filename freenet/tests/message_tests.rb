class MessageTests < Test::Unit::TestCase
  def test_write_message
    m = Freenet::FCP::Message.new('TestMessage', nil, 'Item1' => 'Item1Value', 'Item2' => 'Item2Value')
    s = StringIO.new
    m.write(s)
    assert_equal('TestMessage', s.readline)
    
  end
  
  def test_write_data
  end
end